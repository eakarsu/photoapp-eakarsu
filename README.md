# Photo workflow

This repository's supported product boundary is a dependency-free Ruby photo workflow: durable validated ingest, content-addressed storage, asynchronous preview rendering with provider failover, independent approval, accessible previews, governed export presets, retry/cancel/recovery, and verifiable provenance/audit evidence.

The retained `app/`, `config/`, `db/`, and original `test/` files document a 2016 Rails 4 prototype. That dependency graph and its direct Stripe/upload behavior are retired. `bin/rails`, `bin/rake`, `bin/spring`, `bin/setup`, and the vendored Bundler launcher exit with status 78 and are not release paths.

Local verification requires no gems:

```sh
bin/test
bin/validate_boundary
```

Production startup is fail-closed and requires the variables documented in `.env.example`:

```sh
./start.sh
```

See `OPERATIONS.md`, `PROVIDER_CONTRACTS.md`, and `SECURITY.md` before provisioning any environment.
