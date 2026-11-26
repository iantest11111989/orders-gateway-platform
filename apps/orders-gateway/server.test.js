'use strict';
const test = require('node:test');
const assert = require('node:assert');
process.env.STARTUP_DELAY_MS = '0';
const { server } = require('./server');

test('serves version, readiness, work and metrics', async () => {
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  await new Promise((r) => setTimeout(r, 20));
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/readyz`)).status, 200);
  const w = await (await fetch(`${base}/work?ms=5`)).json();
  assert.equal(w.burned_ms, 5);
  const m = await (await fetch(`${base}/metrics`)).text();
  assert.match(m, /http_requests_total\{route="\/work",method="GET",status="200"\} 1/);
  server.close();
});
