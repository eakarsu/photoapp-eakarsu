require "minitest/autorun"
require "tmpdir"
require_relative "../lib/photo_workflow"

class FakeMediaProvider
  attr_reader :name, :daily_quota, :calls

  def initialize(name, options = {})
    @name = name
    @daily_quota = options.fetch(:daily_quota, 10)
    @failures = options.fetch(:failures, 0)
    @calls = 0
  end

  def render(bytes, content_type, _preset)
    @calls += 1
    if @calls <= @failures
      raise PhotoWorkflow::Error.new("FAKE_PROVIDER_DOWN", "provider unavailable", 503)
    end
    {
      "bytes" => bytes,
      "content_type" => content_type,
      "provider_job_id" => "#{name}-#{@calls}"
    }
  end
end

class PhotoWorkflowTest < Minitest::Test
  CREATOR = { "actor_id" => "creator-1", "role" => "CREATOR" }.freeze
  OTHER_CREATOR = { "actor_id" => "creator-2", "role" => "CREATOR" }.freeze
  REVIEWER = { "actor_id" => "reviewer-1", "role" => "REVIEWER" }.freeze
  OPERATOR = { "actor_id" => "operator-1", "role" => "OPERATOR" }.freeze

  def setup
    @directory = Dir.mktmpdir("photo-workflow-test")
    @store = PhotoWorkflow::Store.new(@directory)
    @primary = FakeMediaProvider.new("primary")
    @secondary = FakeMediaProvider.new("secondary")
    @pool = PhotoWorkflow::ProviderPool.new([@primary, @secondary])
    @service = PhotoWorkflow::Service.new(@store, @pool)
    @now = Time.utc(2026, 7, 20, 12, 0, 0)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_png_validation_rejects_corruption_trailing_data_and_oversized_input
    validator = PhotoWorkflow::MediaValidator.new
    metadata = validator.validate!(png(4, 3), "photo.png", "image/png")
    assert_equal 4, metadata["width"]
    assert_equal 3, metadata["height"]

    error = assert_raises(PhotoWorkflow::Error) { validator.validate!(png(1, 1) + "script", "photo.png", "image/png") }
    assert_equal "TRAILING_MEDIA_DATA", error.code

    corrupt = png(1, 1).dup
    corrupt.setbyte(29, corrupt.getbyte(29) ^ 0xff)
    assert_equal "MALFORMED_PNG", assert_raises(PhotoWorkflow::Error) { validator.validate!(corrupt, "photo.png", "image/png") }.code

    oversized = "x" * (PhotoWorkflow::MediaValidator::MAX_BYTES + 1)
    assert_equal "MEDIA_TOO_LARGE", assert_raises(PhotoWorkflow::Error) { validator.validate!(oversized, "photo.png", "image/png") }.code
  end

  def test_jpeg_validation_checks_dimensions_extension_and_end_marker
    validator = PhotoWorkflow::MediaValidator.new
    metadata = validator.validate!(jpeg(640, 480), "camera.jpeg", "image/jpeg")
    assert_equal [640, 480], [metadata["width"], metadata["height"]]
    assert_equal "FORMAT_MISMATCH", assert_raises(PhotoWorkflow::Error) { validator.validate!(jpeg(1, 1), "camera.png", "image/jpeg") }.code
    assert_equal "MALFORMED_JPEG", assert_raises(PhotoWorkflow::Error) { validator.validate!(jpeg(1, 1)[0...-2], "camera.jpg", "image/jpeg") }.code
  end

  def test_upload_is_durable_idempotent_and_rejects_conflicting_replay
    first = @service.upload(CREATOR, upload_attributes("upload-1"), png(2, 2), @now)
    replay = @service.upload(CREATOR, upload_attributes("upload-1"), png(2, 2), @now + 1)
    assert_equal first["id"], replay["id"]
    assert_equal 1, @store.snapshot["assets"].length

    conflict = assert_raises(PhotoWorkflow::Error) do
      @service.upload(CREATOR, upload_attributes("upload-1"), png(3, 2), @now + 2)
    end
    assert_equal "IDEMPOTENCY_CONFLICT", conflict.code

    reloaded = PhotoWorkflow::Store.new(@directory)
    assert_equal first["id"], reloaded.snapshot["assets"].keys.first
    assert reloaded.verify_audit!
  end

  def test_concurrent_duplicate_upload_creates_one_asset_and_one_job
    results = Queue.new
    threads = 6.times.map do
      Thread.new { results << @service.upload(CREATOR, upload_attributes("same-request"), png(2, 2), @now) }
    end
    threads.each(&:join)
    ids = 6.times.map { results.pop["id"] }
    assert_equal 1, ids.uniq.length
    assert_equal 1, @store.snapshot["jobs"].length
  end

  def test_preview_uses_provider_failover_and_requires_independent_accessible_approval
    primary = FakeMediaProvider.new("primary", :failures => 1)
    secondary = FakeMediaProvider.new("secondary")
    service = PhotoWorkflow::Service.new(@store, PhotoWorkflow::ProviderPool.new([primary, secondary]))
    asset = service.upload(CREATOR, upload_attributes("failover"), png(2, 2), @now)
    job = service.process_next(OPERATOR, @now)
    assert_equal "SUCCEEDED", job["status"]
    assert_equal "secondary", job["provider"]
    assert_equal 1, primary.calls
    assert_equal 1, secondary.calls

    preview_id = job["output_version_id"]
    assert_equal "SEPARATION_REQUIRED", assert_raises(PhotoWorkflow::Error) { service.approve({ "actor_id" => "creator-1", "role" => "ADMIN" }, asset["id"], preview_id, @now) }.code
    approved = service.approve(REVIEWER, asset["id"], preview_id, @now)
    assert_equal "APPROVED", approved["status"]
    html = service.preview_html(REVIEWER, asset["id"], preview_id)
    assert_includes html, "alt=\"Accessible description\""
    assert_includes html, "Editorial caption"
  end

  def test_export_requires_approval_uses_presets_and_is_idempotent
    asset, preview = create_approved_asset
    job = @service.request_export(CREATOR, asset["id"], "social_square", "export-1", @now + 2)
    replay = @service.request_export(CREATOR, asset["id"], "social_square", "export-1", @now + 3)
    assert_equal job["id"], replay["id"]
    completed = @service.process_next(OPERATOR, @now + 3)
    assert_equal "SUCCEEDED", completed["status"]
    record = @service.asset(CREATOR, asset["id"])
    assert_equal 1, record["exports"].length
    assert_equal "social_square", record["exports"].first["preset"]
    assert_equal preview["id"], record["approved_version_id"]
  end

  def test_provider_quota_skips_primary_and_persists_usage
    primary = FakeMediaProvider.new("primary", :daily_quota => 1)
    secondary = FakeMediaProvider.new("secondary")
    service = PhotoWorkflow::Service.new(@store, PhotoWorkflow::ProviderPool.new([primary, secondary]))
    first = service.upload(CREATOR, upload_attributes("quota-1"), png(1, 1), @now)
    second = service.upload(CREATOR, upload_attributes("quota-2"), png(1, 1), @now)
    service.process_next(OPERATOR, @now)
    second_job = service.process_next(OPERATOR, @now)
    assert_equal "secondary", second_job["provider"]
    assert_equal 1, primary.calls
    usage = @store.snapshot["provider_usage"].fetch("2026-07-20")
    assert_equal 1, usage["primary"]
    assert_equal 1, usage["secondary"]
    refute_equal first["id"], second["id"]
  end

  def test_failed_jobs_back_off_can_be_canceled_and_manually_retried
    failing = FakeMediaProvider.new("primary", :failures => 10)
    also_failing = FakeMediaProvider.new("secondary", :failures => 10)
    service = PhotoWorkflow::Service.new(@store, PhotoWorkflow::ProviderPool.new([failing, also_failing]))
    asset = service.upload(CREATOR, upload_attributes("failure"), png(1, 1), @now)
    job_id = asset["job_ids"].first
    assert_raises(PhotoWorkflow::ProviderError) { service.process_next(OPERATOR, @now) }
    queued = @store.snapshot["jobs"].fetch(job_id)
    assert_equal "QUEUED", queued["status"]
    canceled = service.cancel_job(CREATOR, job_id, @now + 1)
    assert_equal "CANCELED", canceled["status"]

    second = service.upload(CREATOR, upload_attributes("failure-2"), png(1, 1), @now + 2)
    failed_id = second["job_ids"].first
    assert_raises(PhotoWorkflow::ProviderError) { service.process_next(OPERATOR, @now + 2) }
    assert_raises(PhotoWorkflow::ProviderError) { service.process_next(OPERATOR, @now + 4) }
    assert_raises(PhotoWorkflow::ProviderError) { service.process_next(OPERATOR, @now + 8) }
    assert_equal "FAILED", @store.snapshot["jobs"].fetch(failed_id)["status"]
    retried = service.retry_job(OPERATOR, failed_id, @now + 9)
    assert_equal "QUEUED", retried["status"]
    assert_equal 0, retried["attempts"]
  end

  def test_http_provider_rejects_private_endpoints_before_any_request
    error = assert_raises(PhotoWorkflow::Error) do
      PhotoWorkflow::HttpProvider.new(
        { "name" => "unsafe", "endpoint" => "https://127.0.0.1/render", "token_env" => "TOKEN" },
        { "TOKEN" => "provider-secret" }
      )
    end
    assert_equal "PROVIDER_ENDPOINT_PRIVATE", error.code
  end

  def test_audit_chain_detects_tampering
    @service.upload(CREATOR, upload_attributes("audit"), png(1, 1), @now)
    state_path = File.join(@directory, "state.json")
    state = JSON.parse(File.read(state_path))
    state["audit"][0]["action"] = "TAMPERED"
    File.write(state_path, JSON.generate(state))
    error = assert_raises(PhotoWorkflow::Error) { @store.verify_audit! }
    assert_equal "AUDIT_CHAIN_INVALID", error.code
  end

  def test_token_authentication_hashes_tokens_and_rejects_unknown_values
    token = "a" * 40
    auth = PhotoWorkflow::TokenAuthenticator.new([
      { "actor_id" => "creator", "role" => "CREATOR", "token_sha256" => Digest::SHA256.hexdigest(token) }
    ])
    assert_equal "creator", auth.authenticate("Bearer #{token}")["actor_id"]
    assert_equal "UNAUTHORIZED", assert_raises(PhotoWorkflow::Error) { auth.authenticate("Bearer #{"b" * 40}") }.code
  end

  def test_runtime_credential_exchange_is_explicit_and_returns_a_verifiable_bearer_session
    password = "runtime-acceptance-password"
    session_token = Digest::SHA256.hexdigest("photoapp-session\0#{password}")
    auth = PhotoWorkflow::TokenAuthenticator.new([
      {
        "actor_id" => "runtime-admin", "email" => "runtime@example.test", "role" => "ADMIN",
        "password_sha256" => Digest::SHA256.hexdigest(password),
        "token_sha256" => Digest::SHA256.hexdigest(session_token)
      }
    ])
    server = PhotoWorkflow::Server.new(@service, auth, "127.0.0.1", 0, ["https://studio.example"], credential_login: true)
    status, _, body = server.dispatch("POST", "/api/auth/login", {}, JSON.generate("email" => "runtime@example.test", "password" => password))
    assert_equal 200, status
    assert_equal session_token, JSON.parse(body).fetch("token")
    me_status, _, me_body = server.dispatch("GET", "/api/auth/me", { "authorization" => "Bearer #{session_token}" }, "")
    assert_equal 200, me_status
    assert_equal "runtime-admin", JSON.parse(me_body).fetch("actor_id")
  end

  def test_server_enforces_origin_auth_and_exposes_fail_closed_readiness
    token = "c" * 40
    auth = PhotoWorkflow::TokenAuthenticator.new([
      { "actor_id" => "creator-1", "role" => "CREATOR", "token_sha256" => Digest::SHA256.hexdigest(token) }
    ])
    server = PhotoWorkflow::Server.new(@service, auth, "127.0.0.1", 0, ["https://studio.example"])
    assert_equal 200, server.dispatch("GET", "/health/live", {}, "").first
    assert_equal 200, server.dispatch("GET", "/health/ready", {}, "").first
    assert_equal 401, server.dispatch("GET", "/v1/assets/unknown", {}, "").first
    headers = { "authorization" => "Bearer #{token}", "origin" => "https://evil.example" }
    assert_equal 403, server.dispatch("GET", "/v1/assets/unknown", headers, "").first
  end

  private

  def create_approved_asset
    asset = @service.upload(CREATOR, upload_attributes("approved"), png(2, 2), @now)
    job = @service.process_next(OPERATOR, @now)
    version = @service.approve(REVIEWER, asset["id"], job["output_version_id"], @now + 1)
    [asset, version]
  end

  def upload_attributes(key)
    {
      "idempotency_key" => key,
      "filename" => "photo.png",
      "content_type" => "image/png",
      "caption" => "Editorial caption",
      "alt_text" => "Accessible description",
      "provenance" => {
        "source" => "camera-import",
        "rights_holder" => "Example Studio",
        "captured_at" => "2026-07-20T11:00:00Z",
        "license" => "owned"
      }
    }
  end

  def png(width, height)
    signature = "\x89PNG\r\n\x1a\n".b
    ihdr = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
    raw = ("\x00" + ("\x00\x00\x00" * width)).b * height
    signature + png_chunk("IHDR", ihdr) + png_chunk("IDAT", Zlib::Deflate.deflate(raw)) + png_chunk("IEND", "".b)
  end

  def png_chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  def jpeg(width, height)
    sof = [8, height, width, 1, 1, 0x11, 0].pack("CnnCCCC")
    "\xff\xd8".b + "\xff\xc0".b + [sof.bytesize + 2].pack("n") + sof + "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00".b + "\x00\xff\xd9".b
  end
end
