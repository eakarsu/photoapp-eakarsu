# Completeness Review: photoapp-eakarsu

**Review date:** 2026-07-18

## Assessment basis

Static inspection of project-owned source and configuration only; no dependency installation, build, database migration, external-service call, or runtime launch was performed. The scan considered 125 project files (42 source files), 1 manifest(s), 15 test-like file(s), and 0 CI workflow(s), excluding dependency/generated directories.

## Classification

**Functional but incomplete**

This is a substantive but unfinished voice/media production application, not just an empty scaffold. Inspection found 42 source files across `app/`, `config/`, `test/`, `.idea/` using Next.js, Rails, Ruby; however, the checked-in workflow and delivery controls do not yet demonstrate a complete, production-operable product.

## Why it is not complete

- Mock, demo, sample, fixture, or placeholder behavior remains in executable/product paths.
- No checked-in CI workflow proves builds, tests, migrations, and security checks on every change.
- No environment template documents required configuration and secret boundaries.
- No clear deployment/container configuration demonstrates a reproducible production topology.

## Needed features

1. Add durable upload, transcoding/rendering, object storage, job status, retry, and cancellation workflows.
2. Integrate production speech/media providers with quotas, format validation, provenance, and provider failover.
3. Implement timeline/version management, preview approval, export presets, captions, and accessible playback.
4. Add fixture-based media pipeline tests plus load limits for large, malformed, and adversarial files.
5. Add risk-based unit, integration, and end-to-end tests in CI, including migration and failure-path coverage.

## Risks or launch blockers

- Weak/fallback secret patterns can permit forged sessions or accidental insecure deployments.
- No CI evidence prevents broken or insecure changes from reaching a release.

## Evidence inspected

- `README.rdoc`
- `config/secrets.yml:3`
- `.idea/workspace.xml:641`
- `config/application.rb`
- `test/test_helper.rb`
- `Gemfile`

## Recommended next action

Choose one real voice/media production journey, define acceptance criteria and external contracts, then close its persistence, permission, integration, failure, and test gaps before expanding features.

## Implementation progress (2026-07-20)

The inherited review's voice/media label was incorrect: this repository is a 2016 Rails photo-upload/payment prototype. The unsupported Rails 4/Stripe/CarrierWave dependency and entry-point boundary is now retired with exit 78, while one dependency-free Ruby photo-ingest-to-approved-export workflow is the supported application.

### Needed-feature status

1. **Durable media lifecycle — implemented.** `lib/photo_workflow/core.rb` implements atomic file-locked JSON persistence, immutable content-addressed objects with read-time digest verification, queued/leased preview and export jobs, three-attempt exponential retry, expired-lease recovery, manual retry, cancellation/cancel-during-run, and persisted statuses/audit evidence. `scripts/backup.sh`, `scripts/restore.sh`, and `bin/verify_store` verify every referenced object and the audit chain before backup/activation.
2. **Providers, quotas, validation, provenance, and failover — implemented.** Configuration-owned providers require credential-free public HTTPS endpoints, TLS peer verification, public DNS resolution, bounded connect/read/response sizes, environment-only bearer credentials, stable idempotency keys, persisted per-provider daily attempt quotas, and ordered failover without false success. PNG/JPEG inputs and hostile provider outputs pass byte, extension/MIME, magic, checksum/marker, dimension, pixel, exact-termination, and content-hash validation. Source, rights holder, capture time, and license provenance are mandatory.
3. **Versions, approval, presets, captions, and accessible preview — implemented.** Assets retain immutable parent-linked originals, previews, approvals, and exports. Captions and alt text are required before a reviewer/admin distinct from the creator can approve; exports require that approval and one of four server-owned presets. The authenticated HTML preview embeds the verified object with semantic figure/caption and escaped alt text.
4. **Adversarial/load/failure coverage — implemented.** Fixture-generated PNG/JPEG tests cover corrupt checksums, truncation/trailing polyglot data, MIME/extension mismatch, missing markers, oversized payloads, unsafe provider endpoints, concurrency/idempotent replay and conflicting replay, quota/failover behavior, backoff/failure/manual retry/cancel, audit tampering, and auth/origin denial.
5. **Risk-based tests and CI — implemented.** `.github/workflows/photo-workflow.yml` runs Ruby 3.3 syntax checks, all tests, the release-boundary validator, legacy exit-78 assertions, full-history Gitleaks, and a non-publishing container build. Docker/Compose provide separate read-only web and worker processes over a private durable volume. Startup requires identities, providers, origins, and storage configuration and never installs dependencies, mutates schemas, seeds data, or controls unrelated processes.

### Security and legacy corrections

- Bearer identities are configured as SHA-256 token digests with creator/reviewer/operator/admin roles; creator reads are owner-scoped, approval separation is mandatory, browser origins are allowlisted, and responses set no-store/CSP/no-sniff/frame/referrer protections.
- The obsolete lockfile is reduced to a zero-gem supported graph. Direct Rails/Rack/Rake/Spring/setup/vendored-Bundler/application/boot/environment paths exit 78 before loading the retired framework. The historical sources remain reference material and are not a release path.
- Two checked-in Rails development/test cookie keys and a commented Devise sample key were removed. Three exact historical fingerprints are baselined only to keep all new findings fatal; any value reused externally still requires owner rotation.
- `LICENSE_STATUS.md` records the absent repository-level license grant; deployment does not authorize redistribution.

### Verification evidence

- Ruby syntax for the supported core, provider, server, server launcher, worker, store verifier, and boundary validator: passed.
- Media/domain/provider/auth/server tests: **12 tests, 62 assertions passed** with zero failures/errors.
- Concurrent duplicate ingest: six threads produced one durable asset and one job; conflicting replay was rejected.
- Live loopback HTTP smoke: liveness/readiness `200`, unauthenticated asset read `401`, and forbidden origin `403`.
- Backup/restore rehearsal: source and restored stores independently verified with identical `1`-audit evidence.
- `bundle check`: passed against the zero-dependency lock graph. Compose configuration, boundary validation, legacy exit-78 checks, and `git diff --check`: passed.
- Current-tree and all seven-commit-history Gitleaks scans: passed with no unbaselined findings.
- Docker image execution was not available because this host has no Docker daemon; CI retains the image-build gate.

### External launch gates

- Provision and certify two real media providers, credentials, quotas, privacy/retention terms, response conformance, failover, and reconciliation behavior.
- Provision a managed durable volume or transactional database/object-store implementation; perform target-environment load, backup/restore, recovery-time, multi-writer, and disaster-recovery acceptance.
- Complete media-rights/privacy/accessibility review, bearer-token rotation/revocation procedures, monitoring/alerting/on-call ownership, operator acceptance, and license/provenance clearance before public release.

## Runtime acceptance verification (2026-07-20)

Production remains a configuration-owned bearer-token API. A credential exchange is enabled only when both `NODE_ENV=test` and the shared validator's `RUNTIME_PROJECT_SOURCE` marker are present. In that isolated path, `start.sh` derives the temporary bearer session and configured identity from the acceptance credentials, retains only SHA-256 digests in identity configuration, uses disposable local storage, and keeps the server bound to the assigned loopback host and port. `/api/auth/me` proves that the returned bearer session is usable.

The first validator attempt failed before binding because shell parameter expansion truncated the temporary provider JSON. Replacing that default with a literal test-only assignment corrected the launcher without changing production configuration requirements. The final run on isolated ports (`55680` reserved disposable database, `6164` API, `6165` browser origin) launched `start.sh`, exchanged the acceptance credentials, authenticated, and verified `/api/auth/me`, recording `API_VERIFIED startup_login_session_api`.

Final verification also passed the supported-boundary validator, all 13 tests with 66 assertions, launcher syntax, and Ruby syntax for the server launcher, server implementation, and test suite. All assigned ports were released afterward.
