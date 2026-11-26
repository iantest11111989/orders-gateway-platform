// CI's performance gate (CI · app, "4 · Performance gate"): the same traffic
// mix as load.js, held to the SLOs (decision 0027) instead of the demos'
// looser checks:
//   - 99.5% of requests "good" (not 5xx; /echo and /version also < 250 ms)
//   - p99 of POST /echo and of GET /version under 250 ms
//   - under 0.5% of requests failed at all (any non-2xx/3xx, or no answer)
// Same environment variables as load.js; CI runs 60 s at 20 requests/s
// against one container, about one prod pod's share at the HPA's 3 pods.
import load from './load.js';

export default load;

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '60s',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: {
    orders_slo_good: ['rate>=0.995'],
    'http_req_duration{name:POST /echo}': ['p(99)<250'],
    'http_req_duration{name:GET /version}': ['p(99)<250'],
    http_req_failed: ['rate<0.005'],
  },
};
