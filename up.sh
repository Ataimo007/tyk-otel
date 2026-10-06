#!/usr/bin/env bash
# Brings the tyk-otel stack up, fully automated. The only prerequisite is a .env with your
# DASHBOARD_LICENCE and MDCB_LICENCE.
#   1. generates per-install secrets (first run only)
#   2. builds the key-hash Go plugin for the pinned gateway version (only if missing)
#   3. starts the containers
#   4. bootstraps Tyk, MDCB and the API consumer scenario (each stage runs once)
#   5. starts the k6 traffic generators
set -euo pipefail
cd "$(dirname "$0")"

command -v docker >/dev/null || { echo "ERROR: docker is required"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required (macOS: brew install jq)"; exit 1; }
command -v openssl >/dev/null || { echo "ERROR: openssl is required"; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running - start Docker Desktop (or the Docker daemon) first"; exit 1; }

if [[ ! -f .env ]]; then
  echo "ERROR: .env missing. Run: cp .env.example .env  and add DASHBOARD_LICENCE and MDCB_LICENCE"
  exit 1
fi
for licence in DASHBOARD_LICENCE MDCB_LICENCE; do
  if ! grep -qE "^${licence}=[^<[:space:]]+" .env; then
    echo "ERROR: $licence is not set in .env"
    exit 1
  fi
done

mkdir -p logs .context
scripts/init-secrets.sh
scripts/build-plugin.sh

echo "Starting containers (first run pulls ~35 images, allow a few minutes)..."
# On a cold start (or a busy laptop) a dependency can miss its healthcheck window and compose
# gives up; it is normally healthy seconds later, so retry before failing.
for attempt in 1 2 3; do
  COMPOSE_PROFILES="" ./dc.sh up -d --quiet-pull --remove-orphans && break
  [[ $attempt == 3 ]] && { echo "ERROR: containers failed to start - see ./dc.sh ps"; exit 1; }
  echo "Some containers were not healthy yet - retrying ($attempt/2)..."
  sleep 15
done

# bootstrap.sh skips any stage that has already run, so this is safe on every up
./bootstrap.sh

echo "Starting traffic generators..."
./dc.sh up -d --quiet-pull consumer-traffic tyk-traffic

./bootstrap.sh --summary
