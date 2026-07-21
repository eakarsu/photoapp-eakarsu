#!/bin/sh
set -eu

if [ "${NODE_ENV:-}" = "test" ] && [ -n "${RUNTIME_PROJECT_SOURCE:-}" ]; then
  : "${ADMIN_EMAIL:?ADMIN_EMAIL is required for runtime acceptance}"
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required for runtime acceptance}"
  export PHOTOAPP_DATA_ROOT="${PHOTOAPP_DATA_ROOT:-$PWD/runtime-photo-data}"
  export PHOTOAPP_ALLOWED_ORIGINS="${PHOTOAPP_ALLOWED_ORIGINS:-${CORS_ALLOWED_ORIGINS:-}}"
  export PHOTOAPP_ENABLE_CREDENTIAL_LOGIN=true
  export PHOTOAPP_RUNTIME_PROVIDER_TOKEN="runtime-acceptance-provider-token"
  if [ -z "${PHOTOAPP_PROVIDERS_JSON:-}" ]; then
    PHOTOAPP_PROVIDERS_JSON='[{"name":"runtime-primary","endpoint":"https://example.com/v1/render-primary","token_env":"PHOTOAPP_RUNTIME_PROVIDER_TOKEN","daily_quota":1},{"name":"runtime-secondary","endpoint":"https://example.com/v1/render-secondary","token_env":"PHOTOAPP_RUNTIME_PROVIDER_TOKEN","daily_quota":1}]'
    export PHOTOAPP_PROVIDERS_JSON
  fi
  if [ -z "${PHOTOAPP_IDENTITIES_JSON:-}" ]; then
    PHOTOAPP_IDENTITIES_JSON="$(ruby -rjson -rdigest -e 'password=ENV.fetch("ADMIN_PASSWORD"); session_token=Digest::SHA256.hexdigest("photoapp-session\0"+password); print JSON.generate([{ "actor_id" => "runtime-admin", "email" => ENV.fetch("ADMIN_EMAIL").downcase, "role" => "ADMIN", "password_sha256" => Digest::SHA256.hexdigest(password), "token_sha256" => Digest::SHA256.hexdigest(session_token) }])')"
    export PHOTOAPP_IDENTITIES_JSON
  fi
fi

: "${PHOTOAPP_DATA_ROOT:?PHOTOAPP_DATA_ROOT is required}"
: "${PHOTOAPP_IDENTITIES_JSON:?PHOTOAPP_IDENTITIES_JSON is required}"
: "${PHOTOAPP_PROVIDERS_JSON:?PHOTOAPP_PROVIDERS_JSON is required}"
: "${PHOTOAPP_ALLOWED_ORIGINS:?PHOTOAPP_ALLOWED_ORIGINS is required}"

exec ruby bin/photo_server
