module PhotoWorkflow
  class TokenAuthenticator
    def self.from_env(environment = ENV)
      raw = environment["PHOTOAPP_IDENTITIES_JSON"]
      raise Error.new("IDENTITIES_NOT_CONFIGURED", "PHOTOAPP_IDENTITIES_JSON is required", 503) if raw.to_s.strip.empty?
      definitions = JSON.parse(raw)
      new(definitions)
    rescue JSON::ParserError
      raise Error.new("IDENTITIES_INVALID", "Identity configuration is invalid JSON", 503)
    end

    def initialize(definitions)
      raise Error.new("IDENTITIES_INVALID", "At least one identity is required", 503) unless definitions.is_a?(Array) && !definitions.empty?
      @identities = definitions.map do |definition|
        digest = String(definition["token_sha256"])
        role = String(definition["role"])
        actor_id = String(definition["actor_id"])
        email = String(definition["email"]).strip.downcase
        password_digest = String(definition["password_sha256"])
        unless digest.match?(/\A[0-9a-f]{64}\z/) && %w[CREATOR REVIEWER OPERATOR ADMIN].include?(role) && !actor_id.empty?
          raise Error.new("IDENTITIES_INVALID", "Identity fields are invalid", 503)
        end
        if !email.empty? && (!email.match?(/\A[^\s@]+@[^\s@]+\z/) || !password_digest.match?(/\A[0-9a-f]{64}\z/))
          raise Error.new("IDENTITIES_INVALID", "Credential identity fields are invalid", 503)
        end
        { "token_sha256" => digest, "role" => role, "actor_id" => actor_id, "email" => email, "password_sha256" => password_digest }
      end
    end

    def authenticate(header)
      scheme, token = String(header).split(" ", 2)
      raise Error.new("UNAUTHORIZED", "Bearer token is required", 401) unless scheme == "Bearer" && token && token.bytesize >= 32
      digest = Digest::SHA256.hexdigest(token)
      identity = @identities.find { |candidate| secure_equal(candidate["token_sha256"], digest) }
      raise Error.new("UNAUTHORIZED", "Bearer token is invalid", 401) unless identity
      identity.reject { |key, _| %w[token_sha256 password_sha256].include?(key) }
    end

    def credential_login(email, password)
      normalized_email = String(email).strip.downcase
      password_digest = Digest::SHA256.hexdigest(String(password))
      identity = @identities.find do |candidate|
        !candidate["email"].empty? && candidate["email"] == normalized_email &&
          secure_equal(candidate["password_sha256"], password_digest)
      end
      raise Error.new("UNAUTHORIZED", "Credentials are invalid", 401) unless identity
      session_token = Digest::SHA256.hexdigest("photoapp-session\0#{password}")
      unless secure_equal(identity["token_sha256"], Digest::SHA256.hexdigest(session_token))
        raise Error.new("UNAUTHORIZED", "Credentials are invalid", 401)
      end
      [identity.reject { |key, _| %w[token_sha256 password_sha256].include?(key) }, session_token]
    end

    private

    def secure_equal(left, right)
      return false unless left.bytesize == right.bytesize
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
      difference.zero?
    end
  end

  class Server
    MAX_REQUEST_BYTES = 14 * 1024 * 1024

    def initialize(service, authenticator, host, port, allowed_origins, credential_login: ENV["PHOTOAPP_ENABLE_CREDENTIAL_LOGIN"] == "true")
      @service = service
      @authenticator = authenticator
      @host = host
      @port = port
      @allowed_origins = allowed_origins
      @credential_login = credential_login
      unless ["127.0.0.1", "::1", "localhost"].include?(@host) || ENV["PHOTOAPP_ALLOW_NON_LOOPBACK"] == "true"
        raise Error.new("UNSAFE_BIND", "Non-loopback bind requires PHOTOAPP_ALLOW_NON_LOOPBACK=true", 503)
      end
    end

    def run
      server = TCPServer.new(@host, @port)
      warn "photo workflow listening on #{@host}:#{@port}"
      loop do
        socket = server.accept
        Thread.new(socket) { |client| handle(client) }
      end
    ensure
      server.close if server
    end

    def dispatch(method, path, headers, body)
      if path == "/health/live" && method == "GET"
        return json_response(200, { "status" => "live" })
      elsif path == "/health/ready" && method == "GET"
        @service.readiness!
        return json_response(200, { "status" => "ready" })
      end

      enforce_origin!(headers)
      if @credential_login && method == "POST" && path == "/api/auth/login"
        payload = body.to_s.empty? ? {} : JSON.parse(body)
        identity, token = @authenticator.credential_login(payload["email"], payload["password"])
        return json_response(200, { "user" => identity, "token" => token })
      end
      identity = @authenticator.authenticate(headers["authorization"])
      payload = body.to_s.empty? ? {} : JSON.parse(body)

      if method == "GET" && path == "/api/auth/me"
        json_response(200, identity)
      elsif method == "POST" && path == "/v1/uploads"
        bytes = Base64.strict_decode64(payload.fetch("content_base64"))
        result = @service.upload(identity, payload.reject { |key, _| key == "content_base64" }, bytes)
        json_response(201, result)
      elsif method == "GET" && path.match?(%r{\A/v1/assets/([^/]+)\z})
        json_response(200, @service.asset(identity, Regexp.last_match(1)))
      elsif method == "POST" && path.match?(%r{\A/v1/assets/([^/]+)/versions/([^/]+)/captions\z})
        result = @service.update_caption(identity, Regexp.last_match(2), payload["caption"], payload["alt_text"])
        json_response(200, result)
      elsif method == "POST" && path.match?(%r{\A/v1/assets/([^/]+)/versions/([^/]+)/approve\z})
        json_response(200, @service.approve(identity, Regexp.last_match(1), Regexp.last_match(2)))
      elsif method == "POST" && path.match?(%r{\A/v1/assets/([^/]+)/exports\z})
        result = @service.request_export(identity, Regexp.last_match(1), payload["preset"], payload["idempotency_key"])
        json_response(202, result)
      elsif method == "POST" && path.match?(%r{\A/v1/jobs/([^/]+)/cancel\z})
        json_response(200, @service.cancel_job(identity, Regexp.last_match(1)))
      elsif method == "POST" && path.match?(%r{\A/v1/jobs/([^/]+)/retry\z})
        json_response(200, @service.retry_job(identity, Regexp.last_match(1)))
      elsif method == "POST" && path == "/v1/jobs/process"
        json_response(200, { "job" => @service.process_next(identity) })
      elsif method == "GET" && path.match?(%r{\A/v1/assets/([^/]+)/versions/([^/]+)/preview\z})
        html = @service.preview_html(identity, Regexp.last_match(1), Regexp.last_match(2))
        [200, { "Content-Type" => "text/html; charset=utf-8" }, html]
      else
        json_response(404, { "error" => "NOT_FOUND" })
      end
    rescue JSON::ParserError, KeyError, ArgumentError
      json_response(400, { "error" => "INVALID_JSON" })
    rescue Error => error
      json_response(error.http_status, { "error" => error.code, "message" => error.message })
    end

    private

    def handle(socket)
      request_line = socket.gets("\r\n", 8_192)
      raise Error.new("BAD_REQUEST", "Request line is invalid", 400) unless request_line
      method, target, protocol = request_line.strip.split(" ", 3)
      raise Error.new("BAD_REQUEST", "Only HTTP/1.1 is supported", 400) unless protocol == "HTTP/1.1"
      headers = {}
      while (line = socket.gets("\r\n", 8_192))
        break if line == "\r\n"
        key, value = line.split(":", 2)
        raise Error.new("BAD_REQUEST", "Header is invalid", 400) unless key && value
        headers[key.downcase] = value.strip
      end
      length = Integer(headers.fetch("content-length", "0"))
      raise Error.new("REQUEST_TOO_LARGE", "Request is too large", 413) if length > MAX_REQUEST_BYTES
      body = length.zero? ? "" : socket.read(length)
      status, response_headers, response_body = dispatch(method, URI.parse(target).path, headers, body)
      response_headers = security_headers.merge(response_headers)
      response_headers["Content-Length"] = response_body.bytesize.to_s
      response_headers["Connection"] = "close"
      socket.write("HTTP/1.1 #{status} #{status_text(status)}\r\n")
      response_headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
      socket.write("\r\n")
      socket.write(response_body)
    rescue Error => error
      write_error(socket, error.http_status, error.code)
    rescue StandardError
      write_error(socket, 500, "INTERNAL_ERROR")
    ensure
      socket.close rescue nil
    end

    def enforce_origin!(headers)
      origin = headers["origin"]
      return unless origin
      raise Error.new("ORIGIN_FORBIDDEN", "Origin is not allowed", 403) unless @allowed_origins.include?(origin)
    end

    def json_response(status, payload)
      [status, { "Content-Type" => "application/json; charset=utf-8" }, JSON.generate(payload)]
    end

    def security_headers
      {
        "Cache-Control" => "no-store",
        "Content-Security-Policy" => "default-src 'none'; img-src data:; style-src 'unsafe-inline'; frame-ancestors 'none'",
        "Referrer-Policy" => "no-referrer",
        "X-Content-Type-Options" => "nosniff",
        "X-Frame-Options" => "DENY"
      }
    end

    def write_error(socket, status, code)
      body = JSON.generate("error" => code)
      socket.write("HTTP/1.1 #{status} #{status_text(status)}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}") rescue nil
    end

    def status_text(status)
      { 200 => "OK", 201 => "Created", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 409 => "Conflict", 413 => "Payload Too Large", 415 => "Unsupported Media Type", 422 => "Unprocessable Entity", 500 => "Internal Server Error", 503 => "Service Unavailable" }.fetch(status, "Error")
    end
  end
end
