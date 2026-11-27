# 3. Loki: filter logs, parse JSON, turn logs into a metric

Time: about 15 minutes. You need a running stack. [Exercise 1](01-prometheus.md) helps for step 5.

You'll select logs by label, filter by text, parse JSON fields, follow one request, and count logs as a metric.

## 0. Start some traffic

1. In a second terminal:

   ```sh
   ./platform shell
   k6 run --quiet -e BASE_URL=http://localhost:8082 -e RATE=5 -e DURATION=15m apps/orders-gateway/app/k6/load.js
   ```

2. In Grafana (<http://localhost:3000>), open Explore, pick the Loki data source, and switch the editor to Code.

Grafana Alloy collects every pod's stdout and sends it to Loki.

## 1. Select by label

```logql
{namespace="dev", app="orders-gateway"}
```

Loki indexes only labels, not text. There are four: `namespace`, `app`, `env` and `pod`.

Each line is one request, as JSON:

```json
{"ts":"…","pod":"orders-gateway-6c9f…","version":"…","level":"info","msg":"request","method":"POST","route":"/echo","status":200,"duration_ms":1}
```

The app logs 5xx at `error` and everything else at `info`. It doesn't log probes or scrapes.

## 2. Filter by text

```logql
{namespace="dev", app="orders-gateway"} |= "/echo"
```

`|=` means contains, `!=` doesn't contain, `|~` and `!~` match a regex. Text filters are fast but blind: `|= "500"` also matches `"duration_ms":500`.

## 3. Parse JSON

1. Make a few 404s (`/echo` only takes `POST`):

   ```sh
   for i in 1 2 3; do curl -s -o /dev/null http://localhost:8082/echo; done
   ```

2. Find them:

   ```logql
   {namespace="dev", app="orders-gateway"} | json | status >= 400
   ```

   `| json` turns each key into a field, so `status >= 400` is a number comparison.

3. Try:
   - `... | json | route="/work" | duration_ms > 40` for slow calls.
   - `... | json | line_format "{{.method}} {{.route}} {{.status}} {{.duration_ms}}ms"` for readable lines.

## 4. Follow one request

The app logs a `trace_id` when a request carries a `traceparent` header.

1. Send one:

   ```sh
   curl -s -X POST http://localhost:8082/echo \
     -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' -d '{"hello":"loki"}'
   ```

2. Find it without knowing the environment or pod:

   ```logql
   {namespace=~"dev|staging|prod", app="orders-gateway"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"
   ```

Per-request values like this go in log lines, not labels. You can search for any of them, and they cost nothing until you do. There's no tracing backend; this is how you follow a request here.

## 5. Logs as a metric

Switch the visualisation to Time series.

1. Requests per minute by route, counted from logs:

   ```logql
   sum by (route) (count_over_time({namespace="dev", app="orders-gateway"} | json [1m]))
   ```

   `/work` is about 180 a minute: the same as Prometheus's 3 a second, plus background traffic.

2. p95 of `/work`, in milliseconds, from every line:

   ```logql
   quantile_over_time(0.95, {namespace="dev", app="orders-gateway"} | json | route="/work" | unwrap duration_ms [5m]) by (route)
   ```

The log version is exact but reads every line. The histogram version from exercise 1 is an estimate between bucket edges, but it's cheap and kept longer, so alerts use it.

## 6. Why labels stay few

Each unique label set is a stream, and each stream costs Loki memory. Count the app's streams:

```logql
count(count by (pod, namespace) (count_over_time({namespace=~"dev|staging|prod", app="orders-gateway"}[1h])))
```

About one per pod. If `trace_id` or `route` were labels, every request or scanner probe would start a new stream. Labels say where a log came from; details stay in the line.

## Check yourself

- What would you write instead of `|= "500"` to find server errors?
- A slow `/echo` shows on the latency panel. How do you find its log lines, and what else would you look for? (Hint: what blocks the event loop?)
- When would you use a LogQL metric instead of a Prometheus one?

Next: [4. SLOs](04-slos.md).
