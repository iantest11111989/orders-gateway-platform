'use strict';
const test = require('node:test');
const assert = require('node:assert');
process.env.VERSION = '9.9.9';
const { server } = require('./server');

test('says hello, reports its version, counts requests', async () => {
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal(await (await fetch(`${base}/`)).text(), 'hello world\n');
  assert.equal((await (await fetch(`${base}/version`)).json()).version, '9.9.9');
  assert.equal((await fetch(`${base}/healthz`)).status, 200);
  assert.equal((await fetch(`${base}/readyz`)).status, 200);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
  const m = await (await fetch(`${base}/metrics`)).text();
  assert.match(m, /http_requests_total\{route="\/",method="GET",status="200"\} 1/);
  assert.match(m, /http_requests_total\{route="other",method="GET",status="404"\} 1/);
  server.close();
});
