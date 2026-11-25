# 3. Loki: filter logs, parse JSON, turn logs into a metric

**Time:** about 15 minutes. **You need:** a running stack. [Exercise 1](01-prometheus.md) helps for step 5.

By the end you will know how to find log lines in Loki by label, filter them by text, parse the app's JSON logs into fields, follow one request through the logs, and count logs as a metric. You'll also know why Loki's labels are kept to a short, fixed list.

## 0. Open Explore and start some traffic

1. Start traffic to dev in a second terminal (as in exercise 1):

   ```sh
   ./platform shell
   k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders.dev.localtest.me -e RATE=5 -e DURATION=15m app/k6/load.js
   ```

2. Open <http://localhost:3000> (`admin` / `admin12345`), go to **Explore** (the compass icon), and pick the **Loki** data source at the top. Switch the query editor from **Builder** to **Code**.

Grafana Alloy collects every pod's stdout and sends it to Loki ([decision 0007](../decisions/0007-observability-stack.md)).

## 1. Select a stream with labels (2 min)

```logql
{namespace="dev", app="app"}
```

Everything inside `{}` is a **label matcher**. Loki stores logs in *streams*, one per unique set of labels, and only indexes the labels, not the text. Here there are just four: `namespace`, `app`, `env` and `pod`. Open the **Label browser** to see them.

Each line is the app's JSON log for one request ([`app/server.js`](../../app/server.js), `log()`):

```json
{"ts":"…","pod":"app-6c9f…","version":"sha-9ab553b…","level":"info","msg":"request","method":"POST","route":"/echo","status":200,"duration_ms":1}
```

The app doesn't log its probes or Prometheus scrapes, so every line is real traffic. It logs 5xx at `error` and everything else, 4xx included, at `info`. Levels are lowercase. It also logs `SIGTERM received, draining` and `drained, exiting` when a pod stops: try `{namespace="dev", app="app"} |= "draining"` after a rollout.

## 2. Filter by text (2 min)

Line filters run after the label selector and scan the text:

```logql
{namespace="dev", app="app"} |= "/echo"
```

- `|=` contains, `!=` doesn't contain, `|~` matches a regex, `!~` doesn't match one.
- Chain them: `|= "/echo" != "\"status\":200"` shows `/echo` requests that didn't succeed.

Line filters are fast, but they're plain text: they don't know that `200` is a status code. `|= "500"` would also match `"duration_ms":500`.

## 3. Parse JSON and filter on fields (3 min)

Send a few requests the app answers with 404 (`/echo` only takes `POST`):

```sh
for i in 1 2 3; do curl -sk -o /dev/null https://orders.dev.localtest.me/echo; done
```

```logql
{namespace="dev", app="app"} | json | status >= 400
```

`| json` turns every JSON key into a field you can filter on, at query time. Now `status >= 400` is a number comparison, and your three 404s show up.

Try a few more:

- The slowest `/work` calls: `... | json | route="/work" | duration_ms > 40`
- Make the lines readable: append `| line_format "{{.method}} {{.route}} {{.status}} {{.duration_ms}}ms {{.pod}}"`
- Errors only: `... | json | level="error"`. It's empty unless the app returns 5xx, which you'll cause on purpose in exercise 4.

## 4. Follow one request (2 min)

The app logs a `trace_id` when the request carries a W3C `traceparent` header. Send one with an ID you choose:

```sh
curl -sk -X POST https://orders.dev.localtest.me/echo \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' -d '{"hello":"loki"}'
```

Then find it anywhere, without knowing which environment or pod served it:

```logql
{namespace=~"dev|staging|prod", app="app"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
```

A real client (or a service mesh) would set `traceparent` on every request, and the same ID would show up in every service's logs for that request. That's why per-request values go in **logs**, not in metric or stream labels: you can search for any one of them, and they cost nothing until you do.

## 5. Turn logs into a metric (4 min)

LogQL can count and measure log lines over time, like PromQL does with samples. Switch the visualisation to **Time series**:

```logql
sum by (route) (count_over_time({namespace="dev", app="app"} | json [1m]))
```

That's requests per minute by route, counted from the logs. Compare it with Prometheus (exercise 1): `/work` at about 180/min is the same as `rate(...)` at about 3/s (k6 at 5 req/s, 60% of them `/work`), plus the trickle.

And a percentile from a field, with `unwrap`:

```logql
quantile_over_time(0.95, {namespace="dev", app="app"} | json | route="/work" | unwrap duration_ms [5m]) by (route)
```

That's the p95 of `/work` time in milliseconds, computed from every log line. Compare it with the histogram estimate from exercise 1: `histogram_quantile(0.95, …http_request_duration_seconds_bucket…{route="/work"})` × 1000. The log version is exact (to the millisecond the app rounds to) but reads every line. The metric version is an estimate between bucket edges (here 25, 50 and 100 ms), but it's cheap, kept longer, and it's what the alerts use.

## 6. Why the labels stay few (2 min)

Every unique label set is a separate **stream**, and Loki keeps an index entry and an open chunk per stream. Count the app's streams:

```logql
count(count by (pod, namespace) (count_over_time({namespace=~"dev|staging|prod", app="app"}[1h])))
```

There's one per pod: a handful. If `trace_id` or `route` (which is the raw path for unknown paths) were a label, every request or every scanner probe would start a new stream, and Loki would slow down and run out of memory, the same cardinality problem as exercise 1. The rule: **labels say where a log came from** (namespace, app, pod), and **everything about the request stays in the line**, where `| json` can reach it.

## Check yourself

- Why is `|= "500"` a poor way to find server errors, and what would you write instead?
- You see a slow `/echo` request on the latency panel. How do you find its log lines, and what else would you look for at the same time? (Hint: what blocks the event loop?)
- When would you use a LogQL metric query instead of a Prometheus metric, and when not?

Next: [4. SLOs](04-slos.md).
