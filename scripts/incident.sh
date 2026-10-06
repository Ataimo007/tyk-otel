#!/usr/bin/env bash
# Live incident for the demo: an ERP 5xx storm on Equipment & Fleet and a legacy-intranet
# burst into its rate limit (429s), on top of the normal traffic. Runs for DURATION (default 5m).
# Watch "Error rate by API key", "Errors by status code" and the Loki row on the API Consumer Insights dashboard.
# Usage: scripts/incident.sh [duration]
set -euo pipefail
cd "$(dirname "$0")/.."
./dc.sh run --rm --no-deps consumer-traffic run --quiet --summary-mode=disabled \
  --env GATEWAY_URL=http://tyk-gateway:8080 --env INCIDENT=1 --env DURATION="${1:-5m}" traffic.js
