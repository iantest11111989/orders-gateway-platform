// k6 load script for orders-gateway.
//
//   BASE_URL  target, default http://localhost:8080
//   RATE      requests per second, default 20
//   DURATION  test length, default 1m
//
// Traffic mix: 70% POST /orders (valid), 25% GET /orders/{id}, 5% invalid
// POST /orders (expected 400). Thresholds mirror the SLO: at least 99.5% of
// POST /orders succeed (non-5xx) and complete in under 300 ms.
import http from 'k6/http';
import { check } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const SKUS = ['SKU-BOOK-1', 'SKU-MUG-2', 'SKU-SHIRT-3', 'SKU-LAMP-4', 'SKU-PEN-5', 'SKU-BAG-6'];

// "Good" per the SLO: not 5xx and faster than 300 ms.
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
    'http_req_duration{name:POST /orders}': ['p(99)<300'],
  },
};

const pick = (a) => a[Math.floor(Math.random() * a.length)];
const hex16 = () => Array.from({ length: 16 }, () => Math.floor(Math.random() * 16).toString(16)).join('');

function order() {
  const items = Array.from({ length: 1 + Math.floor(Math.random() * 3) }, () => ({
    sku: pick(SKUS),
    quantity: 1 + Math.floor(Math.random() * 5),
  }));
  return { customer_id: `cust-${Math.floor(Math.random() * 10000)}`, items };
}

const json = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  const r = Math.random();
  if (r < 0.70) {
    const res = http.post(`${BASE_URL}/orders`, JSON.stringify(order()), { ...json, tags: { name: 'POST /orders' } });
    sloGood.add(res.status > 0 && res.status < 500 && res.timings.duration < 300);
    check(res, { 'created 201': (x) => x.status === 201 });
  } else if (r < 0.95) {
    const res = http.get(`${BASE_URL}/orders/ord_${hex16()}`, { tags: { name: 'GET /orders/{id}' } });
    check(res, { 'found 200': (x) => x.status === 200 });
  } else {
    const res = http.post(`${BASE_URL}/orders`, JSON.stringify({ customer_id: 'cust-1', items: [] }), { ...json, tags: { name: 'POST /orders' } });
    sloGood.add(res.status > 0 && res.status < 500 && res.timings.duration < 300);
    check(res, { 'rejected 400': (x) => x.status === 400 });
  }
}
