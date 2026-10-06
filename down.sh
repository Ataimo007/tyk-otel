#!/usr/bin/env bash
# Tears the stack down and deletes all data: volumes, bootstrap state, generated secrets, logs.
# The next ./up.sh is a fresh install (new secrets, new keys).
# To pause instead and keep everything: ./dc.sh stop   (resume with ./up.sh)
set -euo pipefail
cd "$(dirname "$0")"

# Teardown never uses the secrets or licences, but compose still validates the required ones;
# fill any that are missing (no .env, or secrets already deleted) so down always works.
for v in TYK_GATEWAY_SECRET TYK_NODE_SECRET TYK_ADMIN_SECRET TYK_MDCB_SECRET FLAGD_UI_SECRET_KEY_BASE DASHBOARD_LICENCE MDCB_LICENCE; do
  [[ -f .context/secrets.env ]] && grep -q "^$v=" .context/secrets.env && continue
  [[ -f .env ]] && grep -q "^$v=" .env && continue
  export "$v=unused"
done
[[ -f .env ]] || touch .env
# Include every profile so MDCB containers go too, even if the licence was removed since
COMPOSE_PROFILES=traffic,mdcb ./dc.sh down -v --remove-orphans
rm -rf .context logs/bootstrap.log
echo "tyk-otel removed."
