# Media provider contract

Providers are deployment-owned HTTPS endpoints configured only through `PHOTOAPP_PROVIDERS_JSON`. User input can never choose a provider URL. Endpoints must have no URL credentials and must resolve exclusively to public IP addresses; TLS peer verification, bounded connect/read timeouts, bounded response size, stable idempotency keys, and daily quotas are mandatory.

The service sends JSON:

```json
{
  "input_base64": "<validated PNG or JPEG>",
  "input_content_type": "image/png",
  "preset": { "format": "jpeg", "max_width": 1600, "max_height": 1600, "quality": 82 }
}
```

Headers include `Authorization: Bearer <provider secret>`, `Content-Type: application/json`, and a stable `Idempotency-Key` derived from the source digest and preset. A successful response must be 2xx JSON:

```json
{
  "output_base64": "<rendered media>",
  "content_type": "image/jpeg",
  "provider_job_id": "provider-stable-id"
}
```

Every output is treated as hostile and passes the same media validator before storage. Provider attempts count against the persisted daily quota, including failed attempts. The ordered pool fails over without reporting false success; when all providers fail or exhaust quota, the job remains retryable and the API reports `PROVIDER_FAILURE`.
