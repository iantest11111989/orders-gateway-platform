'use strict';
// "orders-gateway": a small stateless HTTP service. Treat it as a black box you must run in production.
const http = require('http');
const os = require('os');

const VERSION = process.env.VERSION || 'dev';
const PORT = parseInt(process.env.PORT || '8080', 10);
const STARTUP_DELAY_MS = parseInt(process.env.STARTUP_DELAY_MS || '3000', 10);
const POD = process.env.HOSTNAME || os.hostname();

const fault = {
  error_rate: parseFloat(process.env.FAULT_ERROR_RATE || '0'),
  latency_ms: parseInt(process.env.FAULT_LATENCY_MS || '0', 10),
};

let ready = false;
let shuttingDown = false;
let inflight = 0;
setTimeout(() => { ready = true; }, STARTUP_DELAY_MS);

// ---- minimal Prometheus metrics (no dependencies) ----
const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];
const counters = new Map(); // key -> count
const hist = new Map();     // route -> {buckets[], sum, count}
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
  out.push('# TYPE app_inflight_requests gauge', `app_inflight_requests ${inflight}`);
  out.push('# TYPE app_ready gauge', `app_ready ${ready && !shuttingDown ? 1 : 0}`);
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

function log(obj) { process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), pod: POD, version: VERSION, ...obj }) + '\n'); }
function burn(ms) { const end = process.hrtime.bigint() + BigInt(ms) * 1000000n; while (process.hrtime.bigint() < end) { /* busy */ } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'content-type': type, ...(shuttingDown ? { connection: 'close' } : {}) });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const start = process.hrtime.bigint();
  const url = new URL(req.url, 'http://x');
  const route = url.pathname.startsWith('/admin/') ? '/admin' : url.pathname;
  const trace = (req.headers['traceparent'] || '').split('-')[1] || undefined;
  inflight++;
  let status = 200;
  try {
    if (url.pathname === '/healthz') { send(res, 200, { ok: true }); }
    else if (url.pathname === '/readyz') { status = ready && !shuttingDown ? 200 : 503; send(res, status, { ready: status === 200 }); }
    else if (url.pathname === '/metrics') { send(res, 200, metricsText(), 'text/plain; version=0.0.4'); }
    else if (url.pathname === '/version') { send(res, 200, { version: VERSION, pod: POD }); }
    else if (url.pathname === '/work') {
      const ms = Math.min(parseInt(url.searchParams.get('ms') || '10', 10), 2000);
      if (fault.latency_ms) await sleep(fault.latency_ms);
      if (Math.random() < fault.error_rate) { status = 500; send(res, 500, { error: 'injected fault' }); }
      else { burn(ms); send(res, 200, { version: VERSION, pod: POD, burned_ms: ms }); }
    }
    else if (url.pathname === '/echo' && req.method === 'POST') {
      const chunks = []; for await (const c of req) chunks.push(c);
      if (Math.random() < fault.error_rate) { status = 500; send(res, 500, { error: 'injected fault' }); }
      else send(res, 200, Buffer.concat(chunks).toString() || '{}');
    }
    else if (url.pathname === '/admin/fault' && req.method === 'POST') {
      const chunks = []; for await (const c of req) chunks.push(c);
      const b = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (typeof b.error_rate === 'number') fault.error_rate = b.error_rate;
      if (typeof b.latency_ms === 'number') fault.latency_ms = b.latency_ms;
      send(res, 200, fault);
    }
    else { status = 404; send(res, 404, { error: 'not found' }); }
  } catch (e) { status = 500; try { send(res, 500, { error: String(e.message) }); } catch (_) {} }
  finally {
    inflight--;
    const secs = Number(process.hrtime.bigint() - start) / 1e9;
    if (!['/healthz', '/readyz', '/metrics'].includes(url.pathname)) {
      inc(`${route}|${req.method}|${status}`); observe(route, secs);
      log({ level: status >= 500 ? 'error' : 'info', msg: 'request', method: req.method, route, status, duration_ms: Math.round(secs * 1000), trace_id: trace });
    }
  }
});
server.keepAliveTimeout = 65000;

// Graceful but deliberately plain: on SIGTERM, stop accepting new connections, finish in-flight work, exit.
function shutdown() {
  if (shuttingDown) return; shuttingDown = true;
  log({ level: 'info', msg: 'SIGTERM received, draining' });
  server.close(() => { log({ level: 'info', msg: 'drained, exiting' }); process.exit(0); });
  setTimeout(() => process.exit(1), 25000).unref();
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

if (require.main === module) server.listen(PORT, () => log({ level: 'info', msg: `listening on ${PORT}` }));
module.exports = { server };
