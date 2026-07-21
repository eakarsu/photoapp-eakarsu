module PhotoWorkflow
  class Error < StandardError
    attr_reader :code, :http_status

    def initialize(code, message, http_status = 422)
      @code = code
      @http_status = http_status
      super(message)
    end
  end

  class MediaValidator
    MAX_BYTES = 10 * 1024 * 1024
    MAX_DIMENSION = 12_000
    MAX_PIXELS = 40_000_000

    MIME_EXTENSIONS = {
      "image/png" => %w[.png],
      "image/jpeg" => %w[.jpg .jpeg]
    }.freeze

    def validate!(bytes, filename, content_type)
      raise Error.new("EMPTY_MEDIA", "Media is empty") if bytes.nil? || bytes.empty?
      raise Error.new("MEDIA_TOO_LARGE", "Media exceeds #{MAX_BYTES} bytes", 413) if bytes.bytesize > MAX_BYTES

      normalized_type = String(content_type).downcase
      allowed_extensions = MIME_EXTENSIONS[normalized_type]
      raise Error.new("UNSUPPORTED_MEDIA", "Only PNG and JPEG are supported", 415) unless allowed_extensions

      extension = File.extname(String(filename)).downcase
      raise Error.new("FORMAT_MISMATCH", "Filename extension does not match media type", 415) unless allowed_extensions.include?(extension)

      width, height = normalized_type == "image/png" ? validate_png!(bytes) : validate_jpeg!(bytes)
      validate_dimensions!(width, height)

      {
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "bytes" => bytes.bytesize,
        "width" => width,
        "height" => height,
        "content_type" => normalized_type,
        "filename" => File.basename(String(filename))
      }
    end

    private

    def validate_dimensions!(width, height)
      if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION || width * height > MAX_PIXELS
        raise Error.new("UNSAFE_DIMENSIONS", "Media dimensions exceed the processing limits")
      end
    end

    def validate_png!(bytes)
      signature = "\x89PNG\r\n\x1a\n".b
      raise Error.new("MALFORMED_PNG", "Invalid PNG signature", 415) unless bytes.start_with?(signature)

      offset = signature.bytesize
      dimensions = nil
      saw_iend = false
      chunk_count = 0
      while offset < bytes.bytesize
        raise Error.new("MALFORMED_PNG", "Truncated PNG chunk") if offset + 12 > bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        raise Error.new("MALFORMED_PNG", "PNG chunk is too large") if length > MAX_BYTES
        chunk_end = offset + 12 + length
        raise Error.new("MALFORMED_PNG", "Truncated PNG chunk data") if chunk_end > bytes.bytesize

        type = bytes.byteslice(offset + 4, 4)
        data = bytes.byteslice(offset + 8, length)
        expected_crc = bytes.byteslice(offset + 8 + length, 4).unpack1("N")
        actual_crc = Zlib.crc32(type + data)
        raise Error.new("MALFORMED_PNG", "PNG checksum mismatch") unless expected_crc == actual_crc

        chunk_count += 1
        raise Error.new("MALFORMED_PNG", "IHDR must be the first PNG chunk") if chunk_count == 1 && type != "IHDR"
        if type == "IHDR"
          raise Error.new("MALFORMED_PNG", "Invalid IHDR") unless length == 13 && dimensions.nil?
          dimensions = data.byteslice(0, 8).unpack("NN")
        elsif type == "IEND"
          raise Error.new("MALFORMED_PNG", "Invalid IEND") unless length.zero?
          saw_iend = true
          offset = chunk_end
          break
        end
        offset = chunk_end
      end

      raise Error.new("MALFORMED_PNG", "PNG is missing IHDR or IEND") unless dimensions && saw_iend
      raise Error.new("TRAILING_MEDIA_DATA", "PNG contains trailing data") unless offset == bytes.bytesize
      dimensions
    end

    def validate_jpeg!(bytes)
      raise Error.new("MALFORMED_JPEG", "Invalid JPEG markers", 415) unless bytes.start_with?("\xff\xd8".b) && bytes.end_with?("\xff\xd9".b)

      offset = 2
      dimensions = nil
      while offset < bytes.bytesize - 2
        raise Error.new("MALFORMED_JPEG", "Invalid JPEG marker") unless bytes.getbyte(offset) == 0xff
        offset += 1 while offset < bytes.bytesize && bytes.getbyte(offset) == 0xff
        marker = bytes.getbyte(offset)
        raise Error.new("MALFORMED_JPEG", "Truncated JPEG marker") unless marker
        offset += 1
        break if marker == 0xda
        next if marker == 0x01 || (0xd0..0xd7).include?(marker)
        raise Error.new("MALFORMED_JPEG", "Unexpected JPEG end marker") if marker == 0xd9
        raise Error.new("MALFORMED_JPEG", "Truncated JPEG segment") if offset + 2 > bytes.bytesize
        length = bytes.byteslice(offset, 2).unpack1("n")
        raise Error.new("MALFORMED_JPEG", "Invalid JPEG segment length") if length < 2 || offset + length > bytes.bytesize
        if [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].include?(marker)
          raise Error.new("MALFORMED_JPEG", "Invalid JPEG dimensions") if length < 7
          height, width = bytes.byteslice(offset + 3, 4).unpack("nn")
          dimensions = [width, height]
        end
        offset += length
      end

      raise Error.new("MALFORMED_JPEG", "JPEG dimensions are missing") unless dimensions
      dimensions
    end
  end

  class Store
    EMPTY_STATE = {
      "schema_version" => 1,
      "assets" => {},
      "versions" => {},
      "jobs" => {},
      "exports" => {},
      "idempotency" => {},
      "provider_usage" => {},
      "audit" => []
    }.freeze

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      @objects = File.join(@root, "objects")
      @state_path = File.join(@root, "state.json")
      @lock_path = File.join(@root, ".state.lock")
      FileUtils.mkdir_p(@objects, :mode => 0o700)
      File.chmod(0o700, @root) rescue nil
      write_state(deep_copy(EMPTY_STATE)) unless File.exist?(@state_path)
    end

    def snapshot
      with_lock(File::LOCK_SH) { load_state }
    end

    def mutate
      with_lock(File::LOCK_EX) do
        state = load_state
        result = yield(state)
        verify_audit!(state)
        write_state(state)
        result
      end
    end

    def put_object(bytes)
      digest = Digest::SHA256.hexdigest(bytes)
      directory = File.join(@objects, digest[0, 2])
      path = File.join(directory, digest)
      FileUtils.mkdir_p(directory, :mode => 0o700)
      unless File.exist?(path)
        temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
        File.open(temporary, "wb", 0o600) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
      end
      digest
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def get_object(digest)
      raise Error.new("INVALID_DIGEST", "Invalid object digest") unless String(digest).match?(/\A[0-9a-f]{64}\z/)
      path = File.join(@objects, digest[0, 2], digest)
      raise Error.new("OBJECT_NOT_FOUND", "Stored media is missing", 500) unless File.file?(path)
      bytes = File.binread(path)
      raise Error.new("OBJECT_CORRUPT", "Stored media checksum mismatch", 500) unless Digest::SHA256.hexdigest(bytes) == digest
      bytes
    end

    def append_audit!(state, actor, action, entity_type, entity_id, details, at = Time.now.utc)
      previous = state["audit"].empty? ? "0" * 64 : state["audit"].last.fetch("hash")
      entry = {
        "sequence" => state["audit"].length + 1,
        "at" => at.iso8601(6),
        "actor" => actor,
        "action" => action,
        "entity_type" => entity_type,
        "entity_id" => entity_id,
        "details" => details,
        "previous_hash" => previous
      }
      entry["hash"] = Digest::SHA256.hexdigest(previous + canonical_json(entry))
      state["audit"] << entry
      entry
    end

    def verify_audit!(state = snapshot)
      previous = "0" * 64
      state.fetch("audit").each_with_index do |entry, index|
        raise Error.new("AUDIT_SEQUENCE_INVALID", "Audit sequence is invalid", 500) unless entry["sequence"] == index + 1
        expected = Digest::SHA256.hexdigest(previous + canonical_json(entry.reject { |key, _| key == "hash" }))
        raise Error.new("AUDIT_CHAIN_INVALID", "Audit chain verification failed", 500) unless secure_equal(expected, entry["hash"])
        previous = entry["hash"]
      end
      true
    end

    private

    def with_lock(mode)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(mode)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end

    def load_state
      return deep_copy(EMPTY_STATE) unless File.exist?(@state_path)
      JSON.parse(File.read(@state_path))
    rescue JSON::ParserError
      raise Error.new("STATE_CORRUPT", "Workflow state cannot be parsed", 500)
    end

    def write_state(state)
      FileUtils.mkdir_p(@root, :mode => 0o700)
      temporary = "#{@state_path}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, "wb", 0o600) do |file|
        file.write(JSON.pretty_generate(state))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, @state_path)
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def canonical_json(value)
      case value
      when Hash
        "{" + value.keys.sort.map { |key| JSON.generate(key) + ":" + canonical_json(value[key]) }.join(",") + "}"
      when Array
        "[" + value.map { |item| canonical_json(item) }.join(",") + "]"
      else
        JSON.generate(value)
      end
    end

    def secure_equal(left, right)
      return false unless left && right && left.bytesize == right.bytesize
      difference = 0
      left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
      difference.zero?
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end

  class Service
    PRESETS = {
      "web_preview" => { "format" => "jpeg", "max_width" => 1600, "max_height" => 1600, "quality" => 82 },
      "social_square" => { "format" => "jpeg", "width" => 1080, "height" => 1080, "quality" => 88 },
      "print_large" => { "format" => "jpeg", "max_width" => 6000, "max_height" => 6000, "quality" => 95 },
      "accessible_png" => { "format" => "png", "max_width" => 2400, "max_height" => 2400 }
    }.freeze

    def initialize(store, providers, validator = MediaValidator.new)
      @store = store
      @providers = providers
      @validator = validator
    end

    def upload(identity, attributes, bytes, now = Time.now.utc)
      authorize!(identity, %w[CREATOR ADMIN])
      idempotency_key = required_string(attributes, "idempotency_key", 128)
      metadata = @validator.validate!(bytes, required_string(attributes, "filename", 255), required_string(attributes, "content_type", 80))
      provenance = validate_provenance!(attributes["provenance"])
      object_sha = @store.put_object(bytes)
      actor = identity.fetch("actor_id")
      key = "upload:#{actor}:#{idempotency_key}"
      fingerprint = Digest::SHA256.hexdigest(object_sha + JSON.generate(provenance.sort.to_h))

      @store.mutate do |state|
        existing = state["idempotency"][key]
        if existing
          raise Error.new("IDEMPOTENCY_CONFLICT", "Idempotency key was reused with different input", 409) unless existing["fingerprint"] == fingerprint
          next state["assets"].fetch(existing["entity_id"])
        end

        asset_id = "ast_#{SecureRandom.hex(12)}"
        version_id = "ver_#{SecureRandom.hex(12)}"
        job_id = "job_#{SecureRandom.hex(12)}"
        asset = {
          "id" => asset_id,
          "created_by" => actor,
          "created_at" => now.iso8601(6),
          "version_ids" => [version_id],
          "job_ids" => [job_id],
          "approved_version_id" => nil
        }
        state["assets"][asset_id] = asset
        state["versions"][version_id] = metadata.merge(
          "id" => version_id,
          "asset_id" => asset_id,
          "parent_version_id" => nil,
          "object_sha256" => object_sha,
          "status" => "ORIGINAL",
          "caption" => clean_text(attributes["caption"], 2_000),
          "alt_text" => clean_text(attributes["alt_text"], 500),
          "created_by" => actor,
          "created_at" => now.iso8601(6),
          "provenance" => provenance
        )
        state["jobs"][job_id] = new_job(job_id, asset_id, version_id, "PREVIEW", "web_preview", actor, now)
        state["idempotency"][key] = { "entity_id" => asset_id, "fingerprint" => fingerprint }
        @store.append_audit!(state, actor, "UPLOAD_ACCEPTED", "asset", asset_id, { "version_id" => version_id, "sha256" => object_sha }, now)
        asset
      end
    end

    def update_caption(identity, version_id, caption, alt_text, now = Time.now.utc)
      authorize!(identity, %w[CREATOR REVIEWER ADMIN])
      @store.mutate do |state|
        version = state["versions"].fetch(version_id) { raise Error.new("VERSION_NOT_FOUND", "Version was not found", 404) }
        asset = state["assets"].fetch(version["asset_id"])
        unless identity["role"] == "ADMIN" || identity["role"] == "REVIEWER" || asset["created_by"] == identity["actor_id"]
          raise Error.new("FORBIDDEN", "Version is owned by another creator", 403)
        end
        raise Error.new("APPROVED_VERSION_LOCKED", "Approved captions are immutable", 409) if version["status"] == "APPROVED"
        version["caption"] = clean_text(caption, 2_000)
        version["alt_text"] = clean_text(alt_text, 500)
        @store.append_audit!(state, identity["actor_id"], "ACCESSIBILITY_UPDATED", "version", version_id, {}, now)
        version
      end
    end

    def approve(identity, asset_id, version_id, now = Time.now.utc)
      authorize!(identity, %w[REVIEWER ADMIN])
      @store.mutate do |state|
        asset = state["assets"].fetch(asset_id) { raise Error.new("ASSET_NOT_FOUND", "Asset was not found", 404) }
        version = state["versions"].fetch(version_id) { raise Error.new("VERSION_NOT_FOUND", "Version was not found", 404) }
        raise Error.new("VERSION_ASSET_MISMATCH", "Version does not belong to the asset") unless version["asset_id"] == asset_id
        raise Error.new("PREVIEW_REQUIRED", "Only rendered previews can be approved", 409) unless version["status"] == "PREVIEW"
        raise Error.new("SEPARATION_REQUIRED", "Creator cannot approve their own preview", 403) if asset["created_by"] == identity["actor_id"]
        raise Error.new("ACCESSIBILITY_REQUIRED", "Caption and alt text are required") if version["caption"].to_s.empty? || version["alt_text"].to_s.empty?
        version["status"] = "APPROVED"
        version["approved_by"] = identity["actor_id"]
        version["approved_at"] = now.iso8601(6)
        asset["approved_version_id"] = version_id
        @store.append_audit!(state, identity["actor_id"], "PREVIEW_APPROVED", "version", version_id, { "asset_id" => asset_id }, now)
        version
      end
    end

    def request_export(identity, asset_id, preset, idempotency_key, now = Time.now.utc)
      authorize!(identity, %w[CREATOR REVIEWER ADMIN])
      preset_definition = PRESETS[preset]
      raise Error.new("PRESET_NOT_FOUND", "Export preset is not supported") unless preset_definition
      actor = identity.fetch("actor_id")
      key = "export:#{actor}:#{required_string({ "value" => idempotency_key }, "value", 128)}"
      fingerprint = Digest::SHA256.hexdigest("#{asset_id}:#{preset}")

      @store.mutate do |state|
        existing = state["idempotency"][key]
        if existing
          raise Error.new("IDEMPOTENCY_CONFLICT", "Idempotency key was reused with different input", 409) unless existing["fingerprint"] == fingerprint
          next state["jobs"].fetch(existing["entity_id"])
        end
        asset = state["assets"].fetch(asset_id) { raise Error.new("ASSET_NOT_FOUND", "Asset was not found", 404) }
        version_id = asset["approved_version_id"]
        raise Error.new("APPROVAL_REQUIRED", "An approved preview is required", 409) unless version_id
        job_id = "job_#{SecureRandom.hex(12)}"
        job = new_job(job_id, asset_id, version_id, "EXPORT", preset, actor, now)
        job["preset_definition"] = preset_definition
        state["jobs"][job_id] = job
        asset["job_ids"] << job_id
        state["idempotency"][key] = { "entity_id" => job_id, "fingerprint" => fingerprint }
        @store.append_audit!(state, actor, "EXPORT_QUEUED", "job", job_id, { "asset_id" => asset_id, "preset" => preset }, now)
        job
      end
    end

    def cancel_job(identity, job_id, now = Time.now.utc)
      authorize!(identity, %w[CREATOR OPERATOR ADMIN])
      @store.mutate do |state|
        job = state["jobs"].fetch(job_id) { raise Error.new("JOB_NOT_FOUND", "Job was not found", 404) }
        asset = state["assets"].fetch(job["asset_id"])
        unless identity["role"] == "ADMIN" || identity["role"] == "OPERATOR" || asset["created_by"] == identity["actor_id"]
          raise Error.new("FORBIDDEN", "Job is owned by another creator", 403)
        end
        raise Error.new("JOB_TERMINAL", "Completed jobs cannot be canceled", 409) if %w[SUCCEEDED CANCELED].include?(job["status"])
        if job["status"] == "RUNNING"
          job["cancel_requested"] = true
        else
          job["status"] = "CANCELED"
        end
        job["updated_at"] = now.iso8601(6)
        @store.append_audit!(state, identity["actor_id"], "JOB_CANCEL_REQUESTED", "job", job_id, {}, now)
        job
      end
    end

    def retry_job(identity, job_id, now = Time.now.utc)
      authorize!(identity, %w[OPERATOR ADMIN])
      @store.mutate do |state|
        job = state["jobs"].fetch(job_id) { raise Error.new("JOB_NOT_FOUND", "Job was not found", 404) }
        raise Error.new("RETRY_NOT_ALLOWED", "Only failed jobs can be retried", 409) unless job["status"] == "FAILED"
        job["status"] = "QUEUED"
        job["attempts"] = 0
        job["retry_at"] = now.iso8601(6)
        job["last_error"] = nil
        @store.append_audit!(state, identity["actor_id"], "JOB_MANUAL_RETRY", "job", job_id, {}, now)
        job
      end
    end

    def process_next(identity, now = Time.now.utc)
      authorize!(identity, %w[OPERATOR ADMIN])
      claimed = @store.mutate do |state|
        recover_expired_jobs!(state, now)
        job = state["jobs"].values.sort_by { |candidate| candidate["created_at"] }.find do |candidate|
          candidate["status"] == "QUEUED" && Time.parse(candidate["retry_at"]) <= now
        end
        next nil unless job
        job["status"] = "RUNNING"
        job["attempts"] += 1
        job["lease_owner"] = identity["actor_id"]
        job["lease_expires_at"] = (now + 120).iso8601(6)
        job["updated_at"] = now.iso8601(6)
        @store.append_audit!(state, identity["actor_id"], "JOB_CLAIMED", "job", job["id"], { "attempt" => job["attempts"] }, now)
        JSON.parse(JSON.generate(job))
      end
      return nil unless claimed

      source = @store.snapshot["versions"].fetch(claimed["source_version_id"])
      bytes = @store.get_object(source["object_sha256"])
      usage = @store.snapshot["provider_usage"].fetch(now.strftime("%Y-%m-%d"), {})
      response = @providers.render(bytes, source["content_type"], PRESETS.fetch(claimed["preset"]), usage)
      output_name = "#{claimed["id"]}.#{response.fetch("content_type") == "image/png" ? "png" : "jpg"}"
      output_metadata = @validator.validate!(response.fetch("bytes"), output_name, response.fetch("content_type"))
      output_sha = @store.put_object(response.fetch("bytes"))
      finish_success!(claimed, source, response, output_metadata, output_sha, identity, now)
    rescue ProviderError, Error => error
      finish_failure!(claimed, identity, error, now) if claimed
      raise
    end

    def asset(identity, asset_id)
      authorize!(identity, %w[CREATOR REVIEWER OPERATOR ADMIN])
      state = @store.snapshot
      asset = state["assets"].fetch(asset_id) { raise Error.new("ASSET_NOT_FOUND", "Asset was not found", 404) }
      if identity["role"] == "CREATOR" && asset["created_by"] != identity["actor_id"]
        raise Error.new("FORBIDDEN", "Asset is owned by another creator", 403)
      end
      asset.merge(
        "versions" => asset["version_ids"].map { |id| state["versions"].fetch(id) },
        "jobs" => asset["job_ids"].map { |id| state["jobs"].fetch(id) },
        "exports" => state["exports"].values.select { |item| item["asset_id"] == asset_id }
      )
    end

    def preview_html(identity, asset_id, version_id)
      record = asset(identity, asset_id)
      version = record["versions"].find { |item| item["id"] == version_id }
      raise Error.new("VERSION_NOT_FOUND", "Version was not found", 404) unless version
      bytes = @store.get_object(version["object_sha256"])
      source = "data:#{version["content_type"]};base64,#{Base64.strict_encode64(bytes)}"
      caption = CGI.escapeHTML(version["caption"].to_s)
      alt_text = CGI.escapeHTML(version["alt_text"].to_s)
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Approved media preview</title></head><body><main><h1>Media preview</h1><figure><img src=\"#{source}\" alt=\"#{alt_text}\" style=\"max-width:100%;height:auto\"><figcaption>#{caption}</figcaption></figure><p>Status: #{CGI.escapeHTML(version["status"])}</p></main></body></html>"
    end

    def readiness!
      state = @store.snapshot
      @store.verify_audit!(state)
      raise Error.new("PROVIDERS_NOT_CONFIGURED", "At least two media providers are required", 503) unless @providers.ready?
      true
    end

    private

    def new_job(id, asset_id, version_id, kind, preset, actor, now)
      {
        "id" => id,
        "asset_id" => asset_id,
        "source_version_id" => version_id,
        "kind" => kind,
        "preset" => preset,
        "status" => "QUEUED",
        "attempts" => 0,
        "max_attempts" => 3,
        "retry_at" => now.iso8601(6),
        "created_by" => actor,
        "created_at" => now.iso8601(6),
        "updated_at" => now.iso8601(6),
        "cancel_requested" => false
      }
    end

    def finish_success!(job, source, response, metadata, output_sha, identity, now)
      @store.mutate do |state|
        current = state["jobs"].fetch(job["id"])
        record_provider_attempts!(state, response["attempted_providers"], now)
        if current["cancel_requested"]
          current["status"] = "CANCELED"
          @store.append_audit!(state, identity["actor_id"], "JOB_CANCELED", "job", current["id"], {}, now)
          next current
        end

        version_id = "ver_#{SecureRandom.hex(12)}"
        version = metadata.merge(
          "id" => version_id,
          "asset_id" => current["asset_id"],
          "parent_version_id" => source["id"],
          "object_sha256" => output_sha,
          "status" => current["kind"] == "PREVIEW" ? "PREVIEW" : "EXPORTED",
          "caption" => source["caption"],
          "alt_text" => source["alt_text"],
          "created_by" => identity["actor_id"],
          "created_at" => now.iso8601(6),
          "provider" => response["provider"],
          "provider_job_id" => response["provider_job_id"],
          "provenance" => source["provenance"].merge("render_provider" => response["provider"])
        )
        state["versions"][version_id] = version
        state["assets"][current["asset_id"]]["version_ids"] << version_id
        current["status"] = "SUCCEEDED"
        current["output_version_id"] = version_id
        current["provider"] = response["provider"]
        current["provider_job_id"] = response["provider_job_id"]
        current["lease_owner"] = nil
        current["lease_expires_at"] = nil
        current["updated_at"] = now.iso8601(6)
        if current["kind"] == "EXPORT"
          export_id = "exp_#{SecureRandom.hex(12)}"
          state["exports"][export_id] = {
            "id" => export_id,
            "asset_id" => current["asset_id"],
            "version_id" => version_id,
            "preset" => current["preset"],
            "created_at" => now.iso8601(6),
            "created_by" => current["created_by"]
          }
        end
        @store.append_audit!(state, identity["actor_id"], "JOB_SUCCEEDED", "job", current["id"], { "version_id" => version_id, "provider" => response["provider"] }, now)
        current
      end
    end

    def finish_failure!(job, identity, error, now)
      @store.mutate do |state|
        current = state["jobs"].fetch(job["id"])
        attempts = error.respond_to?(:attempted_providers) ? error.attempted_providers : []
        record_provider_attempts!(state, attempts, now)
        current["last_error"] = error.respond_to?(:code) ? error.code : "PROVIDER_FAILURE"
        current["lease_owner"] = nil
        current["lease_expires_at"] = nil
        current["updated_at"] = now.iso8601(6)
        if current["attempts"] >= current["max_attempts"]
          current["status"] = "FAILED"
        else
          current["status"] = "QUEUED"
          current["retry_at"] = (now + [2**current["attempts"], 300].min).iso8601(6)
        end
        @store.append_audit!(state, identity["actor_id"], "JOB_ATTEMPT_FAILED", "job", current["id"], { "error" => current["last_error"], "status" => current["status"] }, now)
        current
      end
    end

    def record_provider_attempts!(state, names, now)
      day = now.strftime("%Y-%m-%d")
      state["provider_usage"][day] ||= {}
      Array(names).each { |name| state["provider_usage"][day][name] = state["provider_usage"][day].fetch(name, 0) + 1 }
    end

    def recover_expired_jobs!(state, now)
      state["jobs"].values.each do |job|
        next unless job["status"] == "RUNNING" && job["lease_expires_at"] && Time.parse(job["lease_expires_at"]) <= now
        job["status"] = job["attempts"] >= job["max_attempts"] ? "FAILED" : "QUEUED"
        job["retry_at"] = now.iso8601(6)
        job["lease_owner"] = nil
        job["lease_expires_at"] = nil
        @store.append_audit!(state, "system", "JOB_LEASE_RECOVERED", "job", job["id"], { "status" => job["status"] }, now)
      end
    end

    def validate_provenance!(value)
      raise Error.new("PROVENANCE_REQUIRED", "Media provenance is required") unless value.is_a?(Hash)
      %w[source rights_holder captured_at license].each { |key| required_string(value, key, 500) }
      Time.iso8601(value["captured_at"])
      value.slice("source", "rights_holder", "captured_at", "license")
    rescue ArgumentError
      raise Error.new("PROVENANCE_INVALID", "captured_at must be ISO-8601")
    end

    def required_string(hash, key, maximum)
      value = String(hash[key]).strip
      raise Error.new("INVALID_INPUT", "#{key} is required") if value.empty?
      raise Error.new("INVALID_INPUT", "#{key} is too long") if value.bytesize > maximum
      value
    end

    def clean_text(value, maximum)
      text = String(value).strip
      raise Error.new("INVALID_INPUT", "Text is too long") if text.bytesize > maximum
      text
    end

    def authorize!(identity, roles)
      unless identity.is_a?(Hash) && roles.include?(identity["role"]) && !String(identity["actor_id"]).empty?
        raise Error.new("FORBIDDEN", "Role is not authorized", 403)
      end
    end
  end
end
