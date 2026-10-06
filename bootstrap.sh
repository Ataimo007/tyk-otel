#!/usr/bin/env bash
# Seeds Tyk with what the observability demo needs:
#   1. the "Tyk Demo" organisation and an admin Dashboard user
#   2. the OpenTelemetry Demo APIs (tyk/apis/*.json), which put Tyk Gateway
#      between the Envoy front door and the shop frontend
#   3. an MDCB Dashboard user, whose key connects the data plane gateway to MDCB
#   4. the API consumer scenario (scenario/setup.sh: APIs, policies, aliased keys)
#
# Secrets and passwords come from .context/secrets.env (scripts/init-secrets.sh).
#
# Each stage runs once (markers in .context/), so re-running is safe.
#
# Everything else (tenant, OAuth, cache, quota and version APIs/policies/keys)
# is created on demand by the traffic scripts in ./scripts.
#
# Usage: ./bootstrap.sh            (called by up.sh on first run)
#        ./bootstrap.sh --summary  (print endpoints and credentials)
set -euo pipefail
cd "$(dirname "$0")"

DASHBOARD_URL="http://localhost:3000"
GATEWAY_URL="http://localhost:8080"
WORKER_GATEWAY_URL="http://localhost:8090"
MDCB_URL="http://localhost:8181"
[[ -s .context/secrets.env ]] || { echo "ERROR: .context/secrets.env missing - run ./up.sh"; exit 1; }
# shellcheck disable=SC1091
source .context/secrets.env
MDCB_SECRET=$TYK_MDCB_SECRET
ADMIN_SECRET=$TYK_ADMIN_SECRET
GATEWAY_SECRET=$TYK_GATEWAY_SECRET
LOG=logs/bootstrap.log

mkdir -p logs .context

log() { echo "$(date -u) $*" >> "$LOG"; }
step() { printf "  %s\n" "$*"; log "$*"; }

print_summary() {
  local email password api_key
  email=$(jq -r .email_address tyk/admin-user.json)
  password=$TYK_ADMIN_PASSWORD
  api_key=$(cat .context/dashboard-api-key 2>/dev/null || echo "not bootstrapped")
  cat <<EOF

▼ Tyk
            Dashboard : $DASHBOARD_URL
             Username : $email
             Password : $password
    Dashboard API Key : $api_key
     Admin API Secret : $ADMIN_SECRET
            Gateway 1 : $GATEWAY_URL
            Gateway 2 : http://localhost:8081
   Gateway API Secret : $GATEWAY_SECRET

▼ MDCB (data plane group: data-plane-1)
          MDCB health : $MDCB_URL/health
      MDCB dataplanes : curl -H "X-Tyk-Authorization: $MDCB_SECRET" $MDCB_URL/dataplanes
   Data plane gateway : $WORKER_GATEWAY_URL

▼ OpenTelemetry Demo (via Envoy :8085 -> Tyk -> frontend)
              Shop UI : http://localhost:8085
              Grafana : http://localhost:8085/grafana/
            Jaeger UI : http://localhost:8085/jaeger/ui
           Prometheus : http://localhost:9090
    Load Generator UI : http://localhost:8085/loadgen/
        Feature Flags : http://localhost:8085/feature/

▼ Traffic (k6 containers, start automatically)
     Consumer traffic : ./dc.sh logs -f consumer-traffic
      Generic traffic : ./dc.sh logs -f tyk-traffic
        Live incident : scripts/incident.sh
EOF
}

if [[ "${1:-}" == "--summary" ]]; then
  print_summary
  exit 0
fi

bootstrap_core() {
  : > "$LOG"
  echo "Bootstrapping Tyk (log: $LOG)"

  # ---------------------------------------------------------------------------
  step "Waiting for Gateway, Dashboard and Redis"
  for attempt in $(seq 1 90); do
    status=$(curl -s "$GATEWAY_URL/hello" || true)
    if [[ "$(jq -r '.status // empty' <<< "$status" 2>/dev/null)" == "pass" &&
          "$(jq -r '.details.dashboard.status // empty' <<< "$status" 2>/dev/null)" == "pass" &&
          "$(jq -r '.details.redis.status // empty' <<< "$status" 2>/dev/null)" == "pass" ]]; then
      break
    fi
    if [[ "$attempt" == 90 ]]; then
      echo "ERROR: Tyk did not become healthy. Check: ./dc.sh logs tyk-dashboard tyk-gateway"
      exit 1
    fi
    sleep 2
  done

  # ---------------------------------------------------------------------------
  org_name=$(jq -r .owner_name tyk/organisation.json)
  step "Creating organisation: $org_name"
  resp=$(curl -s "$DASHBOARD_URL/admin/organisations/import" \
    -H "admin-auth: $ADMIN_SECRET" -d @tyk/organisation.json)
  log "  $resp"
  [[ "$(jq -r '.Status // .status' <<< "$resp")" =~ ^(OK|Ok|ok)$ ]] || { echo "ERROR: $resp"; exit 1; }

  # ---------------------------------------------------------------------------
  email=$(jq -r .email_address tyk/admin-user.json)
  password=$TYK_ADMIN_PASSWORD
  # The traffic scripts grep for these two lines to find the Dashboard API key
  log "Creating Dashboard User: $email"
  printf "  Creating Dashboard user: %s\n" "$email"
  resp=$(curl -s "$DASHBOARD_URL/admin/users" -H "admin-auth: $ADMIN_SECRET" \
    -d "$(jq --arg p "$password" '.password = $p' tyk/admin-user.json)")
  user_id=$(jq -r '.Meta.id // empty' <<< "$resp")
  api_key=$(jq -r '.Meta.access_key // empty' <<< "$resp")
  [[ -n "$api_key" ]] || { echo "ERROR: $resp"; exit 1; }
  log "    API Key: $api_key"
  echo "$api_key" > .context/dashboard-api-key

  resp=$(curl -s "$DASHBOARD_URL/api/users/$user_id/actions/reset" -H "authorization: $api_key" \
    --data-raw '{"new_password":"'"$password"'","user_permissions":{"IsAdmin":"admin"}}')
  log "  password reset: $resp"

  # ---------------------------------------------------------------------------
  step "Creating OpenTelemetry Demo APIs"
  for file in tyk/apis/*.json; do
    name=$(jq -r .api_definition.name "$file")
    resp=$(curl -s "$DASHBOARD_URL/api/apis" -H "Authorization: $api_key" -d @"$file")
    log "  $name: $resp"
    [[ "$(jq -r '.Status // .status' <<< "$resp")" =~ ^(OK|Ok|ok)$ ]] || { echo "ERROR creating $name: $resp"; exit 1; }
    printf "    %s\n" "$name"
  done

  # ---------------------------------------------------------------------------
  step "Reloading gateways and waiting for the Frontend API"
  for attempt in $(seq 1 30); do
    (( attempt % 5 == 1 )) && curl -s "$GATEWAY_URL/tyk/reload/group?block=true" \
      -H "x-tyk-authorization: $GATEWAY_SECRET" >> "$LOG" 2>&1
    code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/tyk/apis/frontend" \
      -H "x-tyk-authorization: $GATEWAY_SECRET")
    [[ "$code" == "200" ]] && break
    if [[ "$attempt" == 30 ]]; then
      echo "ERROR: Gateway did not load the Frontend API"
      exit 1
    fi
    sleep 2
  done

  step "Checking the shop responds through Tyk (frontend can take a minute on first start)"
  for attempt in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/" || true)
    [[ "$code" == "200" ]] && break
    [[ "$attempt" == 30 ]] && echo "  WARNING: frontend not answering yet (last HTTP $code) - it may still be starting"
    sleep 5
  done

  gw2=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8081/tyk/apis/frontend" \
    -H "x-tyk-authorization: $GATEWAY_SECRET" || true)
  if [[ "$gw2" != "200" ]]; then
    echo "  NOTE: Gateway 2 has not loaded APIs - your licence may only allow one gateway node."
  fi


  touch .context/bootstrapped
}

bootstrap_mdcb() {
  local mdcb_email resp mdcb_key code
  echo "Bootstrapping MDCB (log: $LOG)"

  # -------------------------------------------------------------------------
  mdcb_email=$(jq -r .email_address tyk/mdcb-user.json)
  if [[ -s .context/mdcb.env ]]; then
    step "Reusing MDCB Dashboard user key from .context/mdcb.env"
  else
    step "Creating MDCB Dashboard user: $mdcb_email"
    resp=$(curl -s "$DASHBOARD_URL/admin/users" -H "admin-auth: $ADMIN_SECRET" \
      -d "$(jq --arg p "$TYK_MDCB_USER_PASSWORD" '.password = $p' tyk/mdcb-user.json)")
    log "  $resp"
    mdcb_key=$(jq -r '.Meta.access_key // .Message // empty' <<< "$resp")
    [[ -n "$mdcb_key" && "$mdcb_key" != "null" ]] || { echo "ERROR: $resp"; exit 1; }
    log "    MDCB user API Key: $mdcb_key"
    echo "TYK_GW_SLAVEOPTIONS_APIKEY=$mdcb_key" > .context/mdcb.env
  fi

  # -------------------------------------------------------------------------
  step "Waiting for MDCB to be healthy"
  for attempt in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$MDCB_URL/health" || true)
    [[ "$code" == "200" ]] && break
    if [[ "$attempt" == 30 ]]; then
      echo "ERROR: MDCB not healthy (HTTP $code). Check: ./dc.sh logs tyk-mdcb (licence?)"
      exit 1
    fi
    sleep 2
  done

  # -------------------------------------------------------------------------
  step "Recreating the data plane gateway with its MDCB credentials"
  ./dc.sh up -d --no-deps --force-recreate tyk-worker-gateway >> "$LOG" 2>&1

  # An MDCB-connected gateway only exposes a minimal control API (no /tyk/apis),
  # so readiness = the Frontend API (listen path "/") answering through it.
  step "Waiting for the data plane gateway to sync APIs from MDCB"
  for attempt in $(seq 1 45); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$WORKER_GATEWAY_URL/" || true)
    [[ "$code" == "200" ]] && break
    if [[ "$attempt" == 45 ]]; then
      echo "ERROR: data plane gateway not serving APIs (HTTP $code). Check: ./dc.sh logs tyk-worker-gateway tyk-mdcb"
      exit 1
    fi
    sleep 2
  done

  touch .context/mdcb-bootstrapped
}

bootstrap_scenario() {
  echo "Bootstrapping the API consumer scenario (log: $LOG)"
  ./scenario/setup.sh 2>&1 | tee -a "$LOG" | sed 's/^/  /'
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "ERROR: scenario/setup.sh failed"; exit 1; }
  touch .context/scenario-bootstrapped
}

[[ -f .context/bootstrapped ]] || bootstrap_core
[[ -f .context/mdcb-bootstrapped ]] || bootstrap_mdcb
[[ -f .context/scenario-bootstrapped ]] || bootstrap_scenario
echo "Bootstrap complete."
