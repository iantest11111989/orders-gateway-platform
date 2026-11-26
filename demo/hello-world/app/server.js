'use strict';
// "hello-world": the second app of the hello-world demo (./platform demo hello-world).
// It answers "hello world" and exposes the same probes and metrics as orders-gateway,
// so the platform's dashboards, logs and alerts work for it unchanged.
const http = require('http');
const os = require('os');

const VERSION = process.env.VERSION || 'dev';
const PORT = parseInt(process.env.PORT || '8080', 10);
const POD = process.env.HOSTNAME || os.hostname();
const GREETING = process.env.GREETING || 'hello world';

let shuttingDown = false;

// ---- minimal Prometheus metrics (no dependencies), same names as orders-gateway ----
const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];
const counters = new Map(); // "route|method|status" -> count
const hist = new Map();     // route -> {b[], sum, count}
function inc(key) { counters.set(key, (counters.get(key) || 0) + 1); }
function observe(route, seconds) {
  let h = hist.get(route);
  if (!h) { h = { b: BUCKETS.map(() => 0), sum: 0, count: 0 }; hist.set(route, h); }
  BUCKETS.forEach((le, i) => { if (seconds <= le) h.b[i]++; });
  h.sum += seconds; h.count++;
}
function metricsText() {
  const out = [];
  out.push('# TYPE app_info gauge', `app_info{version="${VERSION}"} 1`);
  out.push('# TYPE app_ready gauge', `app_ready ${shuttingDown ? 0 : 1}`);
  out.push('# TYPE http_requests_total counter');
  for (const [k, v] of counters) { const [route, method, status] = k.split('|'); out.push(`http_requests_total{route="${route}",method="${method}",status="${status}"} ${v}`); }
  out.push('# TYPE http_request_duration_seconds histogram');
  for (const [route, h] of hist) {
    BUCKETS.forEach((le, i) => out.push(`http_request_duration_seconds_bucket{route="${route}",le="${le}"} ${h.b[i]}`));
    out.push(`http_request_duration_seconds_bucket{route="${route}",le="+Inf"} ${h.count}`);
    out.push(`http_request_duration_seconds_sum{route="${route}"} ${h.sum}`, `http_request_duration_seconds_count{route="${route}"} ${h.count}`);
  }
  return out.join('\n') + '\n';
}

// One JSON line per request: Alloy ships it to Loki, like orders-gateway's.
function log(obj) { process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), pod: POD, version: VERSION, ...obj }) + '\n'); }
function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'content-type': type, ...(shuttingDown ? { connection: 'close' } : {}) });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}

const server = http.createServer((req, res) => {
  const start = process.hrtime.bigint();
  const path = new URL(req.url, 'http://x').pathname;
  // Known routes only, so a scanner's random paths can't grow the metrics.
  const route = ['/', '/healthz', '/readyz', '/metrics', '/version'].includes(path) ? path : 'other';
  let status = 200;
  if (path === '/') send(res, 200, `${GREETING}\n`, 'text/plain');
  else if (path === '/healthz') send(res, 200, { ok: true });
  else if (path === '/readyz') { status = shuttingDown ? 503 : 200; send(res, status, { ready: status === 200 }); }
  else if (path === '/metrics') send(res, 200, metricsText(), 'text/plain; version=0.0.4');
  else if (path === '/version') send(res, 200, { version: VERSION, pod: POD });
  else { status = 404; send(res, 404, { error: 'not found' }); }
  const seconds = Number(process.hrtime.bigint() - start) / 1e9;
  if (route !== '/metrics' && route !== '/healthz' && route !== '/readyz') {
    inc(`${route}|${req.method}|${status}`); observe(route, seconds);
    log({ level: status >= 500 ? 'error' : 'info', method: req.method, route, status, duration_ms: Math.round(seconds * 1000) });
  }
});

// On SIGTERM: fail readiness, stop accepting connections, exit once they're done.
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  log({ level: 'info', msg: 'SIGTERM received, draining' });
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 10000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

module.exports = { server };
if (require.main === module) server.listen(PORT, () => log({ level: 'info', msg: `listening on ${PORT}` }));
