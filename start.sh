#!/usr/bin/env bash
set -euo pipefail
# Runtime governance modes: check|start. Bare startup uses isolated durable acceptance tables.
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
load_env_file(){ local line key value;while IFS= read -r line||[ -n "$line" ];do [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]]&&continue;line="${line#export }";key="${line%%=*}";value="${line#*=}";key="${key//[[:space:]]/}";[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]||continue;[ -n "${!key+x}" ]&&continue;if [[ "$value" == \"*\" && "$value" == *\" ]];then value="${value:1:${#value}-2}";elif [[ "$value" == \'*\' && "$value" == *\' ]];then value="${value:1:${#value}-2}";fi;export "$key=$value";done < "$ENV_FILE"; }
[ -f "$ENV_FILE" ]||{ echo "Missing required file: $ENV_FILE" >&2;exit 1; };load_env_file
case "${1:-start}" in
  check) cd "$PROJECT_DIR";exec ruby bin/validate_boundary ;;
  start) ;;
  *) echo "Usage: $0 [start|check]" >&2;exit 64 ;;
esac
: "${BACKEND_PORT:?BACKEND_PORT is required}";: "${FRONTEND_PORT:?FRONTEND_PORT is required}";: "${DATABASE_URL:?DATABASE_URL is required}"
: "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}";: "${OPENROUTER_MODEL:?OPENROUTER_MODEL is required}"
[ "${OPENROUTER_BASE_URL:-}" = "https://openrouter.ai/api/v1" ]||{ echo "Exact OPENROUTER_BASE_URL is required" >&2;exit 1; }
[ "$BACKEND_PORT" != "$FRONTEND_PORT" ]||{ echo "Assigned ports must differ" >&2;exit 1; }
for assigned_port in "$BACKEND_PORT" "$FRONTEND_PORT";do [[ "$assigned_port" =~ ^[0-9]+$ ]]||exit 1;nc -z 127.0.0.1 "$assigned_port" >/dev/null 2>&1&&{ echo "Assigned port $assigned_port is occupied" >&2;exit 1; };done
[ -x "$PROJECT_DIR/bin/photo_server" ]&&[ -d "$PROJECT_DIR/runtime" ]||{ echo "Runtime assets are missing" >&2;exit 1; }
export RUNTIME_PROJECT_NAME=photoapp-eakarsu RUNTIME_AI_ENDPOINT=/api/ai/photo-rights-review RUNTIME_AI_FEATURE=photo-rights-review
export RUNTIME_AI_SYSTEM_PROMPT='You are a photo-production governance assistant. Review source provenance, usage rights, consent, accessibility text, transformations, provider evidence, approval separation, retention, and explicit human export gates.'
node "$PROJECT_DIR/runtime/setup.mjs"
photo_data_root="${RUNTIME_PHOTO_DATA_ROOT:-${TMPDIR:-/tmp}/photoapp-eakarsu-runtime-data}"
photo_token='runtime-photo-provider-token'
photo_providers='[{"name":"runtime-primary","endpoint":"https://example.com/v1/render-primary","token_env":"PHOTOAPP_RUNTIME_PROVIDER_TOKEN","daily_quota":1},{"name":"runtime-secondary","endpoint":"https://example.com/v1/render-secondary","token_env":"PHOTOAPP_RUNTIME_PROVIDER_TOKEN","daily_quota":1}]'
photo_identities="$(ruby -rjson -rdigest -e 'password=ENV.fetch("ADMIN_PASSWORD"); token=Digest::SHA256.hexdigest("photoapp-session\0"+password); print JSON.generate([{ "actor_id"=>"runtime-admin", "email"=>ENV.fetch("ADMIN_EMAIL").downcase, "role"=>"ADMIN", "password_sha256"=>Digest::SHA256.hexdigest(password), "token_sha256"=>Digest::SHA256.hexdigest(token) }])')"
export HOST=127.0.0.1 PORT="$FRONTEND_PORT" PHOTOAPP_DATA_ROOT="$photo_data_root"
export PHOTOAPP_ALLOWED_ORIGINS="http://127.0.0.1:$FRONTEND_PORT" PHOTOAPP_ENABLE_CREDENTIAL_LOGIN=true
export PHOTOAPP_RUNTIME_PROVIDER_TOKEN="$photo_token" PHOTOAPP_PROVIDERS_JSON="$photo_providers" PHOTOAPP_IDENTITIES_JSON="$photo_identities"
exec node "$PROJECT_DIR/runtime/supervisor.mjs"
