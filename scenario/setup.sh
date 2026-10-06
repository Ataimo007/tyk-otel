#!/usr/bin/env bash
# API consumer scenario: creates (or refreshes) the three demo APIs, one policy
# per consumer application, and one API key per consumer (the key alias is the
# consumer name shown in the "API Consumer Insights" Grafana dashboard).
#
# Keys are written to .context/consumer-keys.json for scenario/traffic.js.
# Safe to re-run: APIs are updated in place, and existing keys are kept so the
# dashboard's key series stay continuous.
#
# Usage (from the tyk-otel root, stack running): ./scenario/setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DASHBOARD_URL="http://localhost:3000"
GATEWAY_URL="http://localhost:8080"
GATEWAY_SECRET=$(grep -E '^TYK_GATEWAY_SECRET=' .context/secrets.env 2>/dev/null | cut -d= -f2-)
[[ -n "$GATEWAY_SECRET" ]] || { echo "ERROR: .context/secrets.env missing - run ./up.sh first"; exit 1; }
KEYS_FILE=.context/consumer-keys.json
API_KEY=$(cat .context/dashboard-api-key 2>/dev/null) || { echo "ERROR: stack not bootstrapped - run ./up.sh first"; exit 1; }

dash() { curl -s -H "Authorization: $API_KEY" -H "Content-Type: application/json" "$@"; }
api_name() { jq -r .api_definition.name "scenario/apis/${1#demo-}.json"; }
ok() { [[ "$(jq -r '.Status // .status // empty' <<< "$1")" =~ ^(OK|Ok|ok)$ ]]; }

# consumer | API ids it may call (comma separated) | rate per second
CONSUMERS=(
  "site-mobile-app|demo-project-management,demo-equipment-fleet,demo-health-safety|200"
  "bi-reporting|demo-project-management,demo-health-safety|100"
  "iot-telemetry-hub|demo-equipment-fleet|500"
  "erp-integration|demo-project-management,demo-equipment-fleet|100"
  "subcontractor-portal|demo-project-management|50"
  "legacy-intranet|demo-project-management,demo-health-safety|3"
)

echo "API consumer scenario setup"

# ---------------------------------------------------------------------------
echo "  APIs"
existing=$(dash "$DASHBOARD_URL/api/apis?p=-1")
for file in scenario/apis/*.json; do
  api_id=$(jq -r .api_definition.api_id "$file")
  name=$(jq -r .api_definition.name "$file")
  doc_id=$(jq -r --arg id "$api_id" '.apis[]? | select(.api_definition.api_id == $id) | .api_definition.id' <<< "$existing")
  if [[ -n "$doc_id" ]]; then
    body=$(jq --arg doc "$doc_id" '.api_definition.id = $doc' "$file")
    resp=$(dash -X PUT "$DASHBOARD_URL/api/apis/$doc_id" -d "$body")
    action="updated"
  else
    resp=$(dash "$DASHBOARD_URL/api/apis" -d @"$file")
    action="created"
  fi
  ok "$resp" || { echo "ERROR on $name: $resp"; exit 1; }
  echo "    $action $name"
done

# ---------------------------------------------------------------------------
echo "  Policies"
policies=$(dash "$DASHBOARD_URL/api/portal/policies?p=-1")
POLICY_IDS='{}'   # consumer -> policy id (jq map; keeps this bash-3.2 compatible)
for row in "${CONSUMERS[@]}"; do
  IFS='|' read -r consumer apis rate <<< "$row"
  pname="Consumer - $consumer"
  rights=$(for id in ${apis//,/ }; do
    jq -n --arg id "$id" --arg n "$(api_name "$id")" '{($id): {api_id: $id, api_name: $n, versions: ["Default"]}}'
  done | jq -s 'add')
  body=$(jq -n --arg n "$pname" --argjson r "$rate" --argjson ar "$rights" \
    '{name: $n, rate: $r, per: 1, quota_max: -1, quota_renewal_rate: -1, throttle_interval: -1, throttle_retry_limit: -1,
      access_rights: $ar, active: true, is_inactive: false, state: "active", tags: ["consumer-demo"], key_expires_in: 0}')
  pid=$(jq -r --arg n "$pname" '.Data[]? | select(.name == $n) | ._id' <<< "$policies" | head -1)
  if [[ -n "$pid" ]]; then
    resp=$(dash -X PUT "$DASHBOARD_URL/api/portal/policies/$pid" -d "$(jq --arg id "$pid" '._id = $id' <<< "$body")")
  else
    resp=$(dash "$DASHBOARD_URL/api/portal/policies" -d "$body")
    pid=$(jq -r '._id // .Message' <<< "$resp")
  fi
  [[ -n "$pid" && "$pid" != "null" ]] || { echo "ERROR on policy $pname: $resp"; exit 1; }
  POLICY_IDS=$(jq --arg c "$consumer" --arg p "$pid" '.[$c] = $p' <<< "$POLICY_IDS")
  echo "    $pname (rate $rate/s) -> ${apis//,/, }"
done

# ---------------------------------------------------------------------------
echo "  Reloading gateways"
curl -s "$GATEWAY_URL/tyk/reload/group?block=true" -H "x-tyk-authorization: $GATEWAY_SECRET" > /dev/null
# keys can only be created once the gateway has loaded the policies they apply
for pid in $(jq -r '.[]' <<< "$POLICY_IDS"); do
  for attempt in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/tyk/policies/$pid" -H "x-tyk-authorization: $GATEWAY_SECRET")
    [[ "$code" == "200" ]] && break
    (( attempt % 5 == 0 )) && curl -s "$GATEWAY_URL/tyk/reload/group?block=true" -H "x-tyk-authorization: $GATEWAY_SECRET" > /dev/null
    [[ "$attempt" == 30 ]] && { echo "ERROR: gateway did not load policy $pid"; exit 1; }
    sleep 1
  done
done

# The Dashboard stores expires: -1 for new keys (taken from the policy). The gateway treats -1 as
# "never", but the Dashboard key list shows it as Expired - it only treats 0 as "Never Expires".
# Returns 0 if the key had to be changed.
never_expire() {
  local session
  session=$(curl -s "$GATEWAY_URL/tyk/keys/$1" -H "x-tyk-authorization: $GATEWAY_SECRET")
  [[ "$(jq -r .expires <<< "$session")" != "0" ]] || return 1
  curl -s -X PUT "$GATEWAY_URL/tyk/keys/$1?suppress_reset=1" -H "x-tyk-authorization: $GATEWAY_SECRET" \
    -d "$(jq '.expires = 0' <<< "$session")" > /dev/null
}

echo "  API keys (one per consumer)"
[[ -s "$KEYS_FILE" ]] || echo '{}' > "$KEYS_FILE"
for row in "${CONSUMERS[@]}"; do
  IFS='|' read -r consumer _ _ <<< "$row"
  key=$(jq -r --arg c "$consumer" '.[$c] // empty' "$KEYS_FILE")
  if [[ -n "$key" ]]; then
    # keep the key if it still exists (a ./down.sh wipes Redis, so check)
    code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/tyk/keys/$key" -H "x-tyk-authorization: $GATEWAY_SECRET")
    if [[ "$code" == "200" ]]; then
      if never_expire "$key"; then echo "    fixed   $consumer (never expires)"; else echo "    kept    $consumer"; fi
      continue
    fi
  fi
  body=$(jq -n --arg a "$consumer" --arg p "$(jq -r --arg c "$consumer" '.[$c]' <<< "$POLICY_IDS")" \
    '{alias: $a, apply_policies: [$p], expires: 0, allowance: 0, rate: 0, per: 0, quota_max: -1, access_rights: {},
      meta_data: {consumer: $a}}')
  resp=$(dash "$DASHBOARD_URL/api/keys" -d "$body")
  key=$(jq -r '.key_id // .key // empty' <<< "$resp")
  [[ -n "$key" ]] || { echo "ERROR creating key for $consumer: $resp"; exit 1; }
  jq --arg c "$consumer" --arg k "$key" '.[$c] = $k' "$KEYS_FILE" > "$KEYS_FILE.tmp" && mv "$KEYS_FILE.tmp" "$KEYS_FILE"
  never_expire "$key" || true
  echo "    created $consumer (…${key: -6})"
done

# ---------------------------------------------------------------------------
echo "  Smoke test"
k=$(jq -r '."site-mobile-app"' "$KEYS_FILE")
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: $k" "$GATEWAY_URL/pm/projects?status=active")
  [[ "$code" == "200" ]] && break
  sleep 1
done
[[ "$code" == "200" ]] || { echo "ERROR: GET /pm/projects returned $code"; exit 1; }
echo "    GET /pm/projects as site-mobile-app -> 200"
echo "Done. Traffic: the consumer-traffic container (started by ./up.sh)"
