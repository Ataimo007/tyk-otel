# Tyk 5.13 observability: demo runbook

**Audience:** API platform and operations teams.
**Length:** 35 minutes (25 for the story and demo, 10 for questions and next steps).

**Materials**
- Deck: [Tyk-5.13-Observability.pptx](Tyk-5.13-Observability.pptx), 22 slides with speaker notes. Install the fonts in [fonts/](fonts/) if you present from PowerPoint or Keynote; Google Slides already has them.
- Grafana: **API Consumer Insights → API Consumer Insights**, plus the *tyk-demo* folder as backup material.
- Portable copy of the dashboard, for importing into another Grafana: [../scenario/consumer-insights-dashboard.json](../scenario/consumer-insights-dashboard.json)
- Gateway metrics template behind the dashboard: [../scenario/custom-metrics.json](../scenario/custom-metrics.json). It's the value of `opentelemetry.metrics.api_metrics` in `tyk.conf`; for the environment variable, compact it with `jq -c` and set `TYK_GW_OPENTELEMETRY_METRICS_APIMETRICS`.
- Key-hash Go plugin: [../scenario/plugin/](../scenario/plugin/), built automatically by `./up.sh`.

## The story

Most teams already run Grafana, Prometheus and Loki, and want to answer three kinds of question about their APIs:

| Question | Where the demo answers it |
| -------- | ------------------------- |
| Which endpoints are used most, by API and by API key? | The endpoint × API key matrix |
| Which query parameters are used, and by whom? | The query-parameters row |
| How do our API keys compare? | The **API key comparison scorecard** |
| What's our latency, error rate and call volume? | The KPI row, plus the latency, error and call rows, plus a live incident |

The deck tells the same story: why per-key comparison is hard today (slide 3), what changed in 5.13, how it fits an existing stack, and how each question becomes one line of gateway configuration.

## Before the call (T–30 min)

```bash
./up.sh    # from the repository root: starts and bootstraps everything, and starts the traffic
```

- [ ] Let the traffic run for **at least 15 minutes**. `./dc.sh ps consumer-traffic tyk-traffic` should show both running.
- [ ] Open http://localhost:8085/grafana/, go to *API Consumer Insights*, and set the time range to **Last 15 minutes**, refreshing every 30s.
- [ ] Reset the variables to API = All, API key = All, Endpoint = All.
- [ ] Have a terminal ready in the repository root with `scripts/incident.sh 5m` typed but **not** run.
- [ ] Open `otel.env` at the `tyk.consumer.*` instruments, and `scenario/plugin/otel_custom_hash_metrics.go`.
- [ ] Open the deck in presenter view.

## Running order

### 1. Open (3 min, slides 1–3)
- **Slide 1:** introductions and agenda.
- **Slide 2:** the questions teams ask about API usage, latency and errors.
- **Slide 3:** the key insight. Tyk Dashboard keys are base64-encoded JSON, so their last 6 characters are identical for every key (`…Y0In0=`), and "usage by API key" charts collapse into one series. The fix is a key **alias** per consumer app.

> Ask: "How are your consumer keys issued today, through the Dashboard, the Developer Portal or the API? Do they have aliases?"

### 2. What changes in 5.13 (5 min, slides 4–7)
- **Slide 4:** four capabilities, framed as outcomes.
- **Slide 5:** Tyk Pump custom metrics against gateway custom metrics.
- **Slide 6:** how it fits an existing stack. There's no new backend.
- **Slide 7:** each question becomes one dimension in gateway configuration.

### 3. Live demo (15 min, slide 8, then Grafana)

Slides 9–15 are screenshots of the same panels, in the same order. Use them if the environment misbehaves.

| # | Show | Click path | Say |
| - | ---- | ---------- | --- |
| a | **KPI row** (1 min) | Top of dashboard | "Calls, error rate, P95 latency and active keys at a glance." |
| b | **Most-used endpoints** (3 min) | Row *Which endpoints…*, then set **API = Project Management API** | "Across a row: which apps call an endpoint. Down a column: what one app uses." Endpoints are templates (`/projects/{id}`), so the list stays readable. |
| c | **Compare API keys** (3 min) | **API key comparison scorecard**; sort by *Error rate*, then *P95 latency* | Point out each key as `alias (hash)`: **bi-reporting** is the slowest (report generation); **legacy-intranet** shows 429s during its batch sync; **subcontractor-portal** gets 403s on an API it isn't allowed to call. |
| d | **Query parameters** (2 min) | Row *Which query parameters…* | "Every parameter you care about, per endpoint and per key." bi-reporting always asks for `limit=500`. Parameters are declared, so cardinality stays bounded and values never reach the logs. |
| e | **Latency attribution** (2 min) | Row *Latency*, then **Where the time goes** | "Tyk adds milliseconds; the ~0.5–1 s is the backend." |
| f | **Live incident** (3 min) | Run `scripts/incident.sh 5m`, then watch **Error rate by API key**, **Errors by status code** and the Loki row | Within 30–60 s, erp-integration's 5xx and legacy-intranet's 429s climb. "Detect it in metrics, see which key and endpoint, then read the failing calls in Loki." |
| g | **Show the config** (1 min) | `otel.env`, then the plugin source | "Three instruments, scoped to these APIs with `filters.api_ids`. The only code is a 20-line optional plugin that adds the key hash next to the alias." |

If time is short, skip **d** and **g**; never skip **c** or **f**.

### 4. Recap, guardrails and rollout (5 min, slides 16–19)
- **Slide 16:** six-card recap. Pause for questions.
- **Guardrails:** scoped instruments, declared parameters, aliases instead of key fragments, validated config, low overhead.
- **Rollout:** three steps, then a one-week pilot in non-production.

### 5. Questions and next steps (7 min, slides 20–22)
- The FAQ slide is a backup. Use it only if questions stall.
- Close on the next steps (slide 21), and leave slide 22 (references) up.

## Backup material

| Question | Show |
| -------- | ---- |
| Gateway health across nodes or regions | *tyk-demo → Tyk Gateway – Fleet Health*, and the MDCB data-plane gateway |
| A data plane losing its control plane | `./dc.sh stop tyk-mdcb`: the worker gateway keeps serving, and the MDCB health metric drops to 0. `./dc.sh start tyk-mdcb` restores it |
| SLOs | *SLOs for APIs managed by Tyk* |
| Long-term per-request records | Tyk Pump with a SQL sink, separate from the OTel metrics path |

## Known demo behaviours

- **429s come in bursts.** legacy-intranet runs under its 3 req/s limit except for a 20 s batch sync every 5 minutes.
- **HTTP 499** means the client closed the connection. It's harmless, and a good example of a status only the gateway can see.
- **`./down.sh` deletes everything,** including keys and generated secrets. The next `./up.sh` recreates them, with new key hashes.
