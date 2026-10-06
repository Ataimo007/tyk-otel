/**
 * API consumer scenario traffic.
 *
 * Six consumer applications, each with its own API key (alias = consumer name),
 * call three APIs with realistic endpoint mixes and query parameters:
 *
 *   site-mobile-app      all APIs, everyday reads + incident reporting
 *   bi-reporting         big paginated reads (limit=500) + slow report generation
 *   iot-telemetry-hub    high-volume equipment telemetry
 *   erp-integration      maintenance writes (flaky upstream -> 5xx) + milestones
 *   subcontractor-portal project reads; also tries a Safety endpoint it has no access to (403)
 *   legacy-intranet      ~2 req/s under its 3 req/s limit, but a 20s batch sync every 5 min bursts to ~8 req/s
 *                        (-> 429s in bursts), and calls a retired path (404)
 *
 * Run ./scenario/setup.sh first (creates the APIs and keys), then from the tyk-otel root:
 *   k6 run scenario/traffic.js                       # baseline, 30m
 *   k6 run --env DURATION=60m scenario/traffic.js
 *   k6 run --env INCIDENT=1 --env DURATION=5m scenario/traffic.js   # live incident: ERP 5xx storm + intranet burst
 */
import http from 'k6/http';
import { check } from 'k6';

const GATEWAY_URL = __ENV.GATEWAY_URL || 'http://localhost:8080';
const DURATION = __ENV.DURATION || '30m';
const INCIDENT = __ENV.INCIDENT === '1' || __ENV.INCIDENT === 'true';
const KEYS = JSON.parse(open('../.context/consumer-keys.json'));

// ─── Reference data (bounded values keep metric cardinality predictable) ───────
const REGIONS = ['eu-west', 'eu-central', 'eu-south', 'uk', 'us-east'];
const SITES = ['site-north', 'site-south', 'site-east', 'site-west', 'site-central'];
const PROJECT_STATUS = ['active', 'active', 'active', 'planning', 'on-hold', 'completed'];
const EQUIP_TYPE = ['crane', 'excavator', 'loader', 'generator', 'concrete-pump'];
const EQUIP_STATUS = ['available', 'in-use', 'maintenance'];
const SEVERITY = ['low', 'low', 'medium', 'high', 'critical'];
const PHASES = ['design', 'foundation', 'structure', 'finishing'];
const INTERVALS = ['1m', '1m', '5m', '1h'];

const pick = (a) => a[Math.floor(Math.random() * a.length)];
const num = (lo, hi) => lo + Math.floor(Math.random() * (hi - lo + 1));
const projectId = () => `PRJ-${num(1000, 1060)}`;
const equipmentId = () => `EQ-${num(200, 260)}`;
const qs = (o) => Object.entries(o).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');

// Each request: [weight, method, pathFn, bodyFn?]
const CONSUMERS = {
  'site-mobile-app': { rate: 4, requests: [
    [5, 'GET', () => `/pm/projects?${qs({ status: pick(PROJECT_STATUS), region: pick(REGIONS), page: 1, limit: 20 })}`],
    [4, 'GET', () => `/pm/projects/${projectId()}`],
    [3, 'GET', () => `/fleet/equipment?${qs({ site: pick(SITES), status: pick(EQUIP_STATUS) })}`],
    [3, 'GET', () => `/hse/incidents?${qs({ site: pick(SITES), severity: pick(SEVERITY) })}`],
    [1, 'POST', () => '/hse/incidents', () => ({ site: pick(SITES), severity: pick(SEVERITY), type: 'near-miss' })],
  ]},
  'bi-reporting': { rate: 1, requests: [
    [5, 'GET', () => `/pm/projects?${qs({ status: pick(PROJECT_STATUS), page: num(1, 12), limit: 500 })}`],
    [3, 'GET', () => `/hse/incidents?${qs({ region: pick(REGIONS), severity: pick(SEVERITY), page: num(1, 8), limit: 500 })}`],
    [2, 'POST', () => `/pm/projects/${projectId()}/reports`, () => ({ format: 'pdf', period: 'monthly' })],
  ]},
  'iot-telemetry-hub': { rate: 6, requests: [
    [8, 'GET', () => `/fleet/equipment/${equipmentId()}/telemetry?${qs({ interval: pick(INTERVALS) })}`],
    [2, 'GET', () => `/fleet/equipment/${equipmentId()}`],
  ]},
  'erp-integration': { rate: 1, requests: [
    [4, 'POST', () => `/fleet/equipment/${equipmentId()}/maintenance`, () => ({ work_order: `WO-${num(1, 9999)}` })],
    [3, 'GET', () => `/pm/projects/${projectId()}/milestones?${qs({ phase: pick(PHASES) })}`],
    [3, 'GET', () => `/fleet/equipment?${qs({ type: pick(EQUIP_TYPE), status: 'maintenance' })}`],
  ]},
  'subcontractor-portal': { rate: 0.5, requests: [
    [5, 'GET', () => `/pm/projects/${projectId()}`],
    [4, 'GET', () => `/pm/projects/${projectId()}/milestones?${qs({ phase: pick(PHASES) })}`],
    [1, 'GET', () => `/hse/sites/${pick(SITES)}/permits`], // not in its policy -> 403
  ]},
  'legacy-intranet': { rate: 2, burstEvery: 300, burstFor: 20, burstX: 4, requests: [
    [6, 'GET', () => `/pm/projects?${qs({ region: pick(REGIONS) })}`],
    [3, 'GET', () => `/hse/inspections/INS-${num(1, 400)}`],
    [1, 'GET', () => `/pm/project-list`], // retired, untracked endpoint -> 404 (see the API's url_rewrites)
  ]},
};

// ─── Scenarios: one per consumer, plus optional incident bursts ────────────────
const scenarios = {};
for (const [name, c] of Object.entries(CONSUMERS)) {
  // constant-arrival-rate needs an integer rate: express fractions per 10s
  scenarios[name.replace(/-/g, '_')] = {
    executor: 'constant-arrival-rate', exec: 'consumer', env: { CONSUMER: name },
    rate: Math.round(c.rate * 10), timeUnit: '10s', duration: DURATION,
    preAllocatedVUs: Math.max(2, Math.ceil(c.rate * 2)), maxVUs: 40,
  };
}
if (INCIDENT) {
  scenarios.incident_erp_storm = {
    executor: 'constant-arrival-rate', exec: 'erpStorm', rate: 8, timeUnit: '1s',
    duration: DURATION, startTime: '30s', preAllocatedVUs: 10, maxVUs: 40,
  };
  scenarios.incident_intranet_burst = {
    executor: 'constant-arrival-rate', exec: 'consumer', env: { CONSUMER: 'legacy-intranet' },
    rate: 12, timeUnit: '1s', duration: DURATION, startTime: '30s', preAllocatedVUs: 10, maxVUs: 40,
  };
}

export const options = {
  scenarios,
  // 4xx/5xx are part of the story, so don't let k6 treat them as script failures
  thresholds: { checks: ['rate>0.95'] },
  summaryTrendStats: ['avg', 'p(95)', 'max'],
};

function send(consumer, [, method, pathFn, bodyFn]) {
  const url = `${GATEWAY_URL}${pathFn()}`;
  const params = { headers: { Authorization: KEYS[consumer], 'Content-Type': 'application/json' },
                   tags: { consumer } };
  const res = method === 'POST'
    ? http.post(url, JSON.stringify(bodyFn ? bodyFn() : {}), params)
    : http.get(url, params);
  // Anything the gateway deliberately answers (2xx/4xx/5xx) is expected; only network errors fail
  check(res, { 'gateway answered': (r) => r.status > 0 });
}

function weighted(requests) {
  const total = requests.reduce((s, r) => s + r[0], 0);
  let n = Math.random() * total;
  for (const r of requests) { if ((n -= r[0]) < 0) return r; }
  return requests[0];
}

export function setup() {
  const missing = Object.keys(CONSUMERS).filter((c) => !KEYS[c]);
  if (missing.length) throw new Error(`Missing keys for ${missing.join(', ')} - run ./scenario/setup.sh first`);
  console.log(`Consumer traffic: ${Object.keys(CONSUMERS).length} consumers for ${DURATION}${INCIDENT ? ' + INCIDENT bursts after 30s' : ''}`);
}

export function consumer() {
  const name = __ENV.CONSUMER;
  const c = CONSUMERS[name];
  // periodic batch bursts (e.g. the intranet's scheduled sync) multiply the call count for a short window
  const bursting = c.burstEvery && (Math.floor(Date.now() / 1000) % c.burstEvery) < c.burstFor;
  for (let i = 0; i < (bursting ? c.burstX : 1); i++) send(name, weighted(c.requests));
}

export function erpStorm() {
  send('erp-integration', [1, 'POST', () => `/fleet/equipment/${equipmentId()}/maintenance`,
    () => ({ work_order: `WO-${num(1, 9999)}`, retry: true })]);
}
