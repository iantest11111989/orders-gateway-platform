// A minute of light traffic to hello-world in prod, so Grafana has its
// requests and logs to show. Run by step 6 of ./platform demo hello-world.
import http from 'k6/http';
import { check } from 'k6';

const params = { headers: { Host: 'hello-world.localhost' } };

export const options = {
  scenarios: {
    load: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: '1m', preAllocatedVUs: 10, maxVUs: 50 },
  },
  thresholds: { http_req_failed: ['rate<0.01'] },
};

export default function () {
  const res = Math.random() < 0.9
    ? http.get('http://127.0.0.1:8080/', params)
    : http.get('http://127.0.0.1:8080/version', params);
  check(res, { 'status 200': (r) => r.status === 200 });
}
