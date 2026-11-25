// k6 load for orders-gateway (app/server.js).
//
//   BASE_URL  target, default http://localhost:8080
//   RATE      requests per second, default 20
//   DURATION  test length, default 1m
//   WORK_MS   max CPU time per /work call in ms, default 50 (each call picks
//             10..WORK_MS)
//
// Mix: 60% GET /work?ms=10..WORK_MS (CPU on the app's single event loop),
// 30% POST /echo, 10% GET /version. "Good" per the SLOs (decision 0027): not
// 5xx; and for /echo and /version, also under 250 ms. /work's latency is
// what the caller asked for, so only its availability counts.
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const WORK_MS = Number(__ENV.WORK_MS || 50);

// The metric name is read by scripts/demo.sh.
const sloGood = new Rate('orders_slo_good');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '1m',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: {
    orders_slo_good: ['rate>=0.995'],
    'http_req_duration{name:POST /echo}': ['p(99)<250'],
  },
};

const json = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  const r = Math.random();
  if (r < 0.6) {
    const ms = 10 + Math.floor(Math.random() * (WORK_MS - 9));
    const res = http.get(`${BASE_URL}/work?ms=${ms}`, { tags: { name: 'GET /work' } });
    sloGood.add(res.status > 0 && res.status < 500);
    check(res, { 'work 200': (x) => x.status === 200 });
  } else if (r < 0.9) {
    const body = JSON.stringify({ order: `ord-${Math.floor(Math.random() * 1e6)}`, items: 1 + Math.floor(Math.random() * 3) });
    const res = http.post(`${BASE_URL}/echo`, body, { ...json, tags: { name: 'POST /echo' } });
    sloGood.add(res.status > 0 && res.status < 500 && res.timings.duration < 250);
    check(res, { 'echo 200': (x) => x.status === 200 });
  } else {
    const res = http.get(`${BASE_URL}/version`, { tags: { name: 'GET /version' } });
    sloGood.add(res.status > 0 && res.status < 500 && res.timings.duration < 250);
    check(res, { 'version 200': (x) => x.status === 200 });
  }
}
