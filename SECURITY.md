# Security boundary

- No fallback identity, provider credential, signing secret, or production endpoint exists in source.
- Request bodies are length-bounded; only PNG/JPEG with validated structure, checksums/markers, dimensions, and exact termination are accepted.
- Provider URLs are configuration-owned HTTPS endpoints and reject credentialed, unresolved, loopback, link-local, private, and reserved destinations.
- Stored objects are immutable and content-addressed. Workflow state uses file locking and atomic replacement; audit entries form a verified SHA-256 chain.
- Creation, review, operation, and administration are distinct roles. Creators cannot approve their own work.
- Responses use no-store, CSP, no-sniff, clickjacking, and referrer protections; browser origins are allowlisted.
- The 2016 Rails/Stripe/CarrierWave runtime is retired and its entry points exit 78.

Historical development/test cookie keys and a commented Devise example were removed from the current tree. Their exact original-commit fingerprints are baselined only so new findings remain fatal; owners must rotate any value ever reused outside this repository before release.

Report suspected vulnerabilities privately to the repository owner. Do not include credentials, customer media, or unredacted personal data in issue trackers.
