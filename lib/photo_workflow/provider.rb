module PhotoWorkflow
  class ProviderError < Error
    attr_reader :attempted_providers

    def initialize(message, attempted_providers = [])
      @attempted_providers = attempted_providers
      super("PROVIDER_FAILURE", message, 503)
    end
  end

  class ProviderPool
    def self.from_env(environment = ENV)
      raw = environment["PHOTOAPP_PROVIDERS_JSON"]
      raise Error.new("PROVIDERS_NOT_CONFIGURED", "PHOTOAPP_PROVIDERS_JSON is required", 503) if raw.to_s.strip.empty?
      definitions = JSON.parse(raw)
      raise Error.new("PROVIDERS_INVALID", "At least two provider definitions are required", 503) unless definitions.is_a?(Array) && definitions.length >= 2
      providers = definitions.map { |definition| HttpProvider.new(definition, environment) }
      new(providers)
    rescue JSON::ParserError
      raise Error.new("PROVIDERS_INVALID", "Provider configuration is invalid JSON", 503)
    end

    def initialize(providers)
      @providers = providers
    end

    def ready?
      @providers.length >= 2
    end

    def render(bytes, content_type, preset, usage)
      attempted = []
      failures = []
      @providers.each do |provider|
        next if usage.fetch(provider.name, 0) >= provider.daily_quota
        attempted << provider.name
        begin
          response = provider.render(bytes, content_type, preset)
          response["provider"] = provider.name
          response["attempted_providers"] = attempted.dup
          return response
        rescue Error, StandardError => error
          failures << "#{provider.name}:#{error.respond_to?(:code) ? error.code : error.class.name}"
        end
      end
      message = attempted.empty? ? "All provider quotas are exhausted" : "All providers failed: #{failures.join(", ")}"
      raise ProviderError.new(message, attempted)
    end
  end

  class HttpProvider
    MAX_RESPONSE_BYTES = 12 * 1024 * 1024
    PUBLIC_DENYLIST = [
      IPAddr.new("0.0.0.0/8"), IPAddr.new("10.0.0.0/8"), IPAddr.new("100.64.0.0/10"),
      IPAddr.new("127.0.0.0/8"), IPAddr.new("169.254.0.0/16"), IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.0.0.0/24"), IPAddr.new("192.168.0.0/16"), IPAddr.new("198.18.0.0/15"),
      IPAddr.new("224.0.0.0/4"), IPAddr.new("240.0.0.0/4"), IPAddr.new("::/128"),
      IPAddr.new("::1/128"), IPAddr.new("fc00::/7"), IPAddr.new("fe80::/10")
    ].freeze

    attr_reader :name, :daily_quota

    def initialize(definition, environment)
      raise Error.new("PROVIDER_CONFIG_INVALID", "Provider definition must be an object", 503) unless definition.is_a?(Hash)
      @name = required(definition, "name", 80)
      @endpoint = URI.parse(required(definition, "endpoint", 2_000))
      @token_env = required(definition, "token_env", 120)
      @token = environment[@token_env].to_s
      @daily_quota = Integer(definition.fetch("daily_quota", 1_000))
      @open_timeout = Integer(definition.fetch("open_timeout_seconds", 3))
      @read_timeout = Integer(definition.fetch("read_timeout_seconds", 20))
      validate_endpoint!
      raise Error.new("PROVIDER_SECRET_MISSING", "#{@token_env} is required", 503) if @token.empty?
      raise Error.new("PROVIDER_CONFIG_INVALID", "daily_quota must be positive", 503) if @daily_quota <= 0
    rescue URI::InvalidURIError, ArgumentError
      raise Error.new("PROVIDER_CONFIG_INVALID", "Provider configuration is invalid", 503)
    end

    def render(bytes, content_type, preset)
      validate_endpoint!
      request = Net::HTTP::Post.new(@endpoint.request_uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Idempotency-Key"] = Digest::SHA256.hexdigest(Digest::SHA256.hexdigest(bytes) + JSON.generate(preset))
      request.body = JSON.generate(
        "input_base64" => Base64.strict_encode64(bytes),
        "input_content_type" => content_type,
        "preset" => preset
      )

      response = Net::HTTP.start(
        @endpoint.host,
        @endpoint.port,
        :use_ssl => true,
        :open_timeout => @open_timeout,
        :read_timeout => @read_timeout,
        :ssl_timeout => @open_timeout,
        :verify_mode => OpenSSL::SSL::VERIFY_PEER
      ) { |http| http.request(request) }
      raise Error.new("PROVIDER_REJECTED", "Provider returned HTTP #{response.code}", 503) unless response.code.to_i.between?(200, 299)
      raise Error.new("PROVIDER_RESPONSE_TOO_LARGE", "Provider response is too large", 503) if response.body.bytesize > MAX_RESPONSE_BYTES

      payload = JSON.parse(response.body)
      output = Base64.strict_decode64(payload.fetch("output_base64"))
      {
        "bytes" => output,
        "content_type" => payload.fetch("content_type"),
        "provider_job_id" => required(payload, "provider_job_id", 200)
      }
    rescue JSON::ParserError, KeyError, ArgumentError
      raise Error.new("PROVIDER_RESPONSE_INVALID", "Provider response is invalid", 503)
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => error
      raise Error.new("PROVIDER_UNAVAILABLE", "Provider request failed: #{error.class.name}", 503)
    end

    private

    def validate_endpoint!
      unless @endpoint.scheme == "https" && @endpoint.host && @endpoint.userinfo.nil? && @endpoint.fragment.nil?
        raise Error.new("PROVIDER_ENDPOINT_UNSAFE", "Provider endpoint must be credential-free HTTPS", 503)
      end
      addresses = Resolv.getaddresses(@endpoint.host)
      raise Error.new("PROVIDER_ENDPOINT_UNRESOLVED", "Provider hostname does not resolve", 503) if addresses.empty?
      addresses.each do |address|
        ip = IPAddr.new(address)
        raise Error.new("PROVIDER_ENDPOINT_PRIVATE", "Provider hostname resolves to a private address", 503) if PUBLIC_DENYLIST.any? { |range| range.include?(ip) }
      end
    rescue Resolv::ResolvError, IPAddr::InvalidAddressError
      raise Error.new("PROVIDER_ENDPOINT_UNRESOLVED", "Provider hostname is invalid", 503)
    end

    def required(hash, key, maximum)
      value = String(hash[key]).strip
      raise Error.new("PROVIDER_CONFIG_INVALID", "#{key} is required", 503) if value.empty? || value.bytesize > maximum
      value
    end
  end
end
