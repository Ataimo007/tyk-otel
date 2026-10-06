#!/usr/bin/env bash
# docker compose wrapper. Loads, in order: otel.env (pinned versions and settings),
# .env (your licences) and .context/secrets.env (secrets generated on first ./up.sh).
# The "traffic" profile (k6 generators) is included unless COMPOSE_PROFILES is set.
# The "mdcb" profile (MDCB + data plane gateway) is added whenever .env has an MDCB_LICENCE;
# without one the stack runs as a plain Tyk Self-Managed (Tyk Pro) install.
# Usage: ./dc.sh ps | ./dc.sh logs -f tyk-gateway | ./dc.sh restart otel-collector
cd "$(dirname "$0")"
profiles="${COMPOSE_PROFILES-traffic}"
if [[ -f .env ]] && grep -qE '^MDCB_LICENCE=[^<[:space:]]+' .env; then
  profiles="${profiles:+$profiles,}mdcb"
else
  # Envoy's third gateway route normally targets the MDCB data plane gateway
  export TYK_WORKER_GATEWAY_HOST=tyk-gateway
fi
export COMPOSE_PROFILES="$profiles"
args=(--env-file otel.env --env-file .env)
[[ -f .context/secrets.env ]] && args+=(--env-file .context/secrets.env)
exec docker compose "${args[@]}" -f docker-compose.yml "$@"
