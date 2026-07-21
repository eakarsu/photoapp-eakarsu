# Photo workflow operations

## Supported journey

Creators upload PNG or JPEG media with a stable idempotency key, caption, alt text, and source/rights/capture/license provenance. The service validates magic bytes, checksums, dimensions, pixel and byte ceilings, extension/MIME agreement, container termination, and content hashes before atomically storing an immutable object and queueing a preview.

Operators run `bin/photo_worker`. Jobs use leases, bounded three-attempt exponential backoff, provider quotas and ordered failover. Expired leases recover on the next claim. Creators may cancel queued work; operators can manually release failed work for a fresh retry. A reviewer other than the creator must approve a captioned, accessible preview before any named export preset can be queued.

## Identity and data

`PHOTOAPP_IDENTITIES_JSON` stores only SHA-256 token digests plus actor IDs and roles. Raw bearer tokens are provisioned through a secret manager and sent only in `Authorization: Bearer`. Roles are `CREATOR`, `REVIEWER`, `OPERATOR`, and `ADMIN`; creator reads are owner-scoped and approval separation is mandatory.

`PHOTOAPP_DATA_ROOT` must be a durable private volume. `state.json` is written by atomic rename under an exclusive file lock. Media objects are content-addressed and reverified on read. This single-writer/file-lock topology is suitable for one host; multi-host deployment requires a transactional database/object-store implementation preserving the same invariants.

## Backup and restore

Set `BACKUP_PATH` and run `scripts/backup.sh`; it verifies the audit chain and every referenced object before creating an atomic archive. Restore only into an absent or empty target using `RESTORE_SOURCE` and `RESTORE_TARGET` with `scripts/restore.sh`. Restore rejects absolute, traversal, and unexpected-root archive entries and verifies the complete restored store before activation.

## Release checklist

1. Provision at least two HTTPS render providers and verify independent quotas/failure domains.
2. Generate distinct bearer tokens, store only their SHA-256 digests in identity configuration, and test revocation/rotation.
3. Mount a private durable volume, perform backup/restore rehearsal, and record recovery time and recovery point evidence.
4. Run `bin/test`, `bin/validate_boundary`, syntax checks, secret scans, and the container build.
5. Complete provider privacy/retention/DPA review, media-rights policy review, load tests, monitoring, alerting, and operator acceptance.
