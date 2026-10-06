# tyk-otel

A self-contained demo environment for **Tyk 5.13 native OpenTelemetry observability**: metrics, logs and traces from the Tyk Gateway flow through an OTel Collector into Prometheus, Loki/OpenSearch and Jaeger/Tempo, and appear in ready-made Grafana dashboards.

It includes a complete **API consumer scenario**: three APIs, six consumer applications with aliased API keys, custom gateway metrics, a key-hash Go plugin, a dedicated Grafana dashboard, a presentation deck and a demo runbook.

**All you provide is your licence.** Versions are pinned, templates and dashboards are predefined, secrets are generated per install, and the setup, plugin build and traffic generation are automated.

## Quick start

**Prerequisites**
- Docker with **at least 8 GB RAM** allocated (Docker Desktop on macOS or Windows, or Docker Engine on Linux)
- `jq` and `openssl` on the host
- A **Tyk Dashboard licence** (Tyk Self-Managed / Tyk Pro)
- *Optional:* a **Tyk MDCB licence**, plus pull access to the private `tykio/tyk-mdcb-docker` image (`docker login` with an account that has access)

```bash
cp .env.example .env     # then paste your DASHBOARD_LICENCE (and MDCB_LICENCE, if you have one)
./up.sh
```

**Two modes, chosen automatically from `.env`:**

| `.env` has | You get |
| ---------- | ------- |
| `DASHBOARD_LICENCE` only | **Tyk Self-Managed (Tyk Pro):** Dashboard, two gateways, Pump. MDCB and the data-plane gateway are skipped. |
| `DASHBOARD_LICENCE` + `MDCB_LICENCE` | Everything above, plus **MDCB** and a **data-plane gateway** (group `data-plane-1`). |

The whole observability demo (dashboards, custom metrics, plugin, traffic) works the same in both modes. To add MDCB later, put `MDCB_LICENCE` in `.env` and run `./up.sh` again; only the MDCB stage runs. To drop it, remove the licence and run `./down.sh && ./up.sh`.

That's it. `./up.sh`:
1. generates per-install secrets and passwords into `.context/secrets.env` (first run only)
2. builds the key-hash Go plugin for the pinned gateway version, if no build exists for your CPU architecture
3. pulls and starts about 40 containers
4. bootstraps Tyk (organisation, admin user, APIs), MDCB if licensed (data-plane connection), and the API consumer scenario (APIs, policies, keys)
5. starts the traffic generators
6. prints the URLs and credentials

The first run takes about 5–10 minutes, and `up.sh` prints which mode it's using. The plugin is committed prebuilt for linux/arm64 and linux/amd64, so nothing is compiled unless you change `GATEWAY_VERSION` (then allow 10–20 minutes for the one-off build). Let traffic run for **about 15 minutes** before demoing, so every panel has a full time range.

`./bootstrap.sh --summary` prints the URLs and credentials again at any time.

| What | Where |
| ---- | ----- |
| Grafana (no login) | http://localhost:8085/grafana/ → *API Consumer Insights* and *tyk-demo* folders |
| Tyk Dashboard | http://localhost:3000 (`admin-user@example.org`, password from `./bootstrap.sh --summary`) |
| Gateway 1 / 2 (control plane) | http://localhost:8080 / http://localhost:8081 |
| Worker gateway (MDCB data plane, MDCB mode only) | http://localhost:8090 |
| MDCB health (MDCB mode only) | http://localhost:8181/health |
| Shop UI (Envoy → Tyk → frontend) | http://localhost:8085 |
| Jaeger / Prometheus | http://localhost:8085/jaeger/ui / http://localhost:9090 |
| Locust / feature flags | http://localhost:8085/loadgen/ / http://localhost:8085/feature/ |

## Lifecycle

| Command | Effect |
| ------- | ------ |
| `./up.sh` | Start or resume. Each bootstrap stage runs only once, so it's safe to re-run |
| `./dc.sh stop` | Pause and keep all data. Resume with `./up.sh` |
| `./down.sh` | Delete everything: containers, volumes, generated secrets, keys. The next `./up.sh` is a fresh install |
| `./dc.sh <args>` | `docker compose` with the right env files, e.g. `./dc.sh ps`, `./dc.sh logs -f tyk-gateway` |
| `scripts/incident.sh [5m]` | Live incident: an ERP 5xx storm and an intranet rate-limit burst |
| `scripts/build-plugin.sh --force` | Rebuild the key-hash plugin |

Prometheus keeps 1 hour of metrics, so after a long pause the dashboards start nearly empty. The traffic generators restart with the stack and refill them.

## Pinned versions

Set in [otel.env](otel.env). Don't override them in `.env`: the plugin and dashboards are built for these.

| Component | Version |
| --------- | ------- |
| Tyk Gateway | v5.13.3 |
| Tyk Dashboard | v5.13.3 |
| Tyk MDCB (optional) | v2.13.0 |
| Tyk Pump | v1.15.0 |
| Key-hash plugin | built with `tykio/tyk-plugin-compiler:v5.13.3` |
| OpenTelemetry Demo | 2.1.3 (prebuilt images) |
| OTel Collector / Prometheus / Grafana / Loki | 0.133.0 / v3.5.0 / 12.2.0 / 3.5.0 |
| k6 (traffic generators) | 1.7.1 |

## What's inside

```
                                   ┌─ Control plane ─────────────────────────────┐
                                   │ Dashboard ─ Redis ─ Mongo ─ Pump  ─ MDCB     │
Browser / Locust ─► Envoy :8085 ─┬─┼─► Gateway 1 :8080                            │
k6 (consumer + Tyk scenarios) ───┼─┼─► Gateway 2 :8081                            │
                  (round robin)  │ └──────────────────────────────────────────────┘
                                 │ ┌─ Data plane (MDCB mode only) ────────────────┐
                                 └─┼─► Worker Gateway :8090 (via MDCB, own Redis)  │
                                   └──────────────────────────────────────────────┘
                                             │  gateways proxy to the shop and the demo APIs
                                             ▼
 Gateways ── OTLP metrics + traces, JSON logs ─┐
 MDCB ────── logs, /health probe ──────────────┼─► OTel Collector ─► Prometheus (metrics)
 Demo app ── OTLP ─────────────────────────────┘                  ├─► Jaeger + Tempo (traces)
                                                                  └─► Loki + OpenSearch (logs)
```

| Layer | Services |
| ----- | -------- |
| Tyk control plane | Dashboard, Gateway, Gateway 2, Pump (Mongo + Prometheus `:8092`), Redis, Mongo, httpbin; plus MDCB in MDCB mode |
| Tyk data plane (MDCB mode only) | Worker gateway (group `data-plane-1`), Worker Redis |
| OTel Demo app | 15 microservices, Envoy front door, Locust, flagd, Kafka, Postgres, Valkey |
| Telemetry | OTel Collector, Prometheus, Loki, OpenSearch, Jaeger, Tempo, Grafana |
| Traffic | `consumer-traffic` and `tyk-traffic` (k6 containers, run continuously in 6-hour cycles) |

**How Tyk telemetry gets out**
- **Metrics:** gateways push OTLP using the instruments in `TYK_GW_OPENTELEMETRY_METRICS_APIMETRICS` ([otel.env](otel.env)). The Pump also exposes classic analytics for the SLO dashboard.
- **Traces:** OTLP spans, 10% sampled.
- **Logs:** JSON gateway and access logs. The collector reads them from Docker's log files (containers tagged `tyk-gateway`) and ships them to Loki and OpenSearch.
- **MDCB (MDCB mode only):** logs to Loki as `service_name="tyk-mdcb"`, plus a `/health` probe as a Prometheus metric. Without MDCB the probe reports it as down; ignore the MDCB panels in *Fleet Health*.

## Grafana dashboards

| Folder / dashboard | For |
| ------------------ | --- |
| **API Consumer Insights → API Consumer Insights** | Usage by endpoint and API key, query parameters, per-key comparison scorecard, latency (P50/P95/P99, gateway vs upstream), errors by cause, Loki access logs |
| tyk-demo → Fleet Health | Gateways, config drift, Go runtime, gateway logs |
| tyk-demo → API Portfolio Overview | Estate KPIs, leaderboards, tenants, consumer identity, SLOs |
| tyk-demo → API Troubleshooting | One API: latency attribution, response flags, traces, correlated logs |
| tyk-demo → Native OTLP Metrics | Every instrument and dimension source |
| tyk-demo → SLOs for APIs managed by Tyk | Recording rules over Pump metrics |
| Demo | Upstream OTel Demo dashboards |

The consumer dashboard is also exported for import into another Grafana (it prompts for Prometheus and Loki): [scenario/consumer-insights-dashboard.json](scenario/consumer-insights-dashboard.json).

## The API consumer scenario

| Piece | Where |
| ----- | ----- |
| 3 APIs: Project Management `/pm/`, Equipment & Fleet `/fleet/`, Health & Safety `/hse/` | [scenario/apis/](scenario/apis/): tracked endpoints, context variables, auth token, plugin hook |
| 6 consumer apps, each with a policy and an **aliased key**: site-mobile-app, bi-reporting, iot-telemetry-hub, erp-integration, subcontractor-portal, legacy-intranet | Created by [scenario/setup.sh](scenario/setup.sh) during bootstrap |
| Realistic traffic: query parameters, slow reports, flaky ERP writes, 403s, 404s and 429 bursts | [scenario/traffic.js](scenario/traffic.js) (`consumer-traffic` container) |
| Custom metrics `tyk.consumer.requests`, `tyk.consumer.request.duration`, `tyk.consumer.query_params`, scoped to these APIs with `filters.api_ids` | [otel.env](otel.env); standalone template: [scenario/custom-metrics.json](scenario/custom-metrics.json) |
| Key-hash Go plugin: each key is shown as `alias (hash)` | [scenario/plugin/](scenario/plugin/) |
| Deck, runbook and fonts | [docs/](docs/) |

> **Why aliases:** the built-in `session · api_key` dimension records a key's last 6 characters. Every Dashboard-issued key ends in the same characters (`…Y0In0=`, because keys are base64-encoded JSON), so it can't tell keys apart. The demo identifies keys by **alias**, plus the key hash from the plugin.

### Key-hash plugin

`HashAPIKey` runs at `post_key_auth` and writes the key's hash (the same hash the Tyk Dashboard shows) to the context variable `hashed_api_key`. The metrics record it as `key_hash`.

- **Version-locked:** a Go plugin only loads into the exact gateway build it was compiled for. [scripts/build-plugin.sh](scripts/build-plugin.sh) builds `otel_custom_hash_metrics_<GATEWAY_VERSION>_linux_<arch>.so` with `tykio/tyk-plugin-compiler:<GATEWAY_VERSION>`, for the Docker host's architecture.
- **Automatic:** `./up.sh` runs the script and skips the build when a matching `.so` already exists. The committed builds are `v5.13.3` for `linux/arm64` (Apple silicon, ARM servers) and `linux/amd64`. Rebuild with `scripts/build-plugin.sh --force`.
- **Version-agnostic config:** the API definitions reference `otel_custom_hash_metrics.so`, and the gateway loads the build matching its own version and architecture.

## Secrets and credentials

Nothing secret is committed:
- **Your licence(s)** live in `.env`, which is git-ignored.
- **Generated secrets and passwords** (gateway, node, Dashboard admin, MDCB, user passwords) are created on first `./up.sh` in `.context/secrets.env`, which is git-ignored. The configs in [tyk/](tyk/) only contain `SET_VIA_ENV_*` placeholders; the real values are injected as environment variables.
- **Runtime state** (Dashboard API key, MDCB user key, consumer keys) is also kept in `.context/`.
- **Reset:** `./down.sh` deletes `.context/`, and the next install gets fresh secrets.

## Configuration

Other settings live in [otel.env](otel.env). Put any overrides in `.env`.

| Want to… | Set |
| -------- | --- |
| See every request as a trace | `TYK_GW_OPENTELEMETRY_TRACES_SAMPLING_RATE=1` |
| Change gateway log level | `TYK_GW_LOGLEVEL`. Keep `info` or `debug`: access logs are written at info |
| Add or change metric instruments | `TYK_GW_OPENTELEMETRY_METRICS_APIMETRICS` (JSON array; `api_metrics` replaces the defaults, so keep them) |
| Change shop load | `LOCUST_USERS` |
| Forward everything to Grafana Cloud | `GRAFANA_CLOUD_OTLP_ENDPOINT`, `GRAFANA_CLOUD_INSTANCE_ID` and `GRAFANA_CLOUD_API_KEY` in `.env`, then uncomment [otel/otel-collector/otelcol-config-extras.yml](otel/otel-collector/otelcol-config-extras.yml) |

Run `./up.sh` again after changing env values. Edits to mounted config files need a restart of that service, e.g. `./dc.sh restart otel-collector`.

## Extra traffic and reports

The two k6 containers cover all dashboards. These one-shot scripts are optional; run them from the repository root:

| Script | Populates |
| ------ | --------- |
| `bash scripts/tenant-traffic-gen.sh` | Multi-tenancy panels |
| `bash scripts/oauth-traffic-gen.sh` | OAuth client panels |
| `bash scripts/version-traffic-gen.sh` | Backend version and content-type panels |
| `bash scripts/traffic-control-demo.sh` | Cache, quota and rate-limit panels |
| `bash scripts/gateway-signals-report.sh` | A Markdown report of metrics, logs and traces in `reports/` |
| `bash scripts/path-signals-report.sh` | A path-dimension report in `reports/` |

## Layout

```
.
├── up.sh · down.sh · dc.sh · bootstrap.sh    lifecycle (only up.sh is needed)
├── docker-compose.yml                        the whole stack
├── otel.env                                  pinned versions and settings (committed)
├── .env.example                              licence template (MDCB optional); copy to .env
├── tyk/                                      Tyk configs (secrets are placeholders), org, users, OTel Demo APIs
├── otel/                                     collector, Prometheus, Grafana (dashboards, alerting), Loki, Tempo, Jaeger, Envoy, flagd
├── scenario/                                 demo APIs, setup.sh, traffic.js, plugin/, custom-metrics.json, portable dashboard
├── scripts/                                  init-secrets, build-plugin, incident, traffic and report scripts
└── docs/                                     deck (.pptx), demo runbook, fonts
```

## Troubleshooting

| Symptom | Check |
| ------- | ----- |
| `up.sh`: "Docker is not running" | Start Docker Desktop or the Docker daemon |
| Stuck at "Waiting for Gateway, Dashboard and Redis" | `./dc.sh logs tyk-dashboard`. Usually an invalid or expired Dashboard licence |
| Stuck at "Waiting for MDCB to be healthy" | `./dc.sh logs tyk-mdcb`. Usually the MDCB licence. To run without MDCB, remove `MDCB_LICENCE` from `.env` and run `./down.sh && ./up.sh` |
| MDCB image fails to pull | `tykio/tyk-mdcb-docker` is private: `docker login` with an account that has access |
| Plugin build fails | `logs/plugin-build.log`. Retry with `scripts/build-plugin.sh --force`; network errors during the dependency download are usually transient |
| Gateway 2 missing from Fleet Health | Your licence allows only one gateway node; everything else still works |
| Dashboards empty | `./dc.sh ps consumer-traffic tyk-traffic` should show both running; wait 1–2 minutes for the first data points |
| Containers OOM-killed or restarting | Give Docker more memory (8 GB or more) |

> Don't run this alongside tyk-demo's `opentelemetry-demo` deployment: they use the same container names and ports.

Based on the `opentelemetry-demo` deployment of [tyk-demo](https://github.com/TykTechnologies/tyk-demo) and the [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/).
