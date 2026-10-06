#!/usr/bin/env bash
# docker compose wrapper. Loads, in order: otel.env (pinned versions and settings),
# .env (your licences) and .context/secrets.env (secrets generated on first ./up.sh).
# The "traffic" profile (k6 generators) is included unless COMPOSE_PROFILES is set.
# Usage: ./dc.sh ps | ./dc.sh logs -f tyk-gateway | ./dc.sh restart otel-collector
cd "$(dirname "$0")"
export COMPOSE_PROFILES="${COMPOSE_PROFILES-traffic}"
args=(--env-file otel.env --env-file .env)
[[ -f .context/secrets.env ]] && args+=(--env-file .context/secrets.env)
exec docker compose "${args[@]}" -f docker-compose.yml "$@"
