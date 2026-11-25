# 3. Loki: filter logs, parse JSON, turn logs into a metric

**Time:** about 15 minutes. **You need:** a running stack. [Exercise 1](01-prometheus.md) helps for step 5.

By the end you will know how to find log lines in Loki by label, filter them by text, parse the app's JSON logs into fields, follow one order through the logs, and count logs as a metric. You'll also know why Loki's labels are kept to a short, fixed list.

## 0. Open Explore and start some traffic

1. Start traffic to dev in a second terminal (as in exercise 1):

   ```sh
   ./platform shell
   k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders.dev.localtest.me -e RATE=5 -e DURATION=15m app/k6/load.js
   ```

2. Open <https://grafana.localtest.me> (login from `./platform urls`), go to **Explore** (the compass icon), and pick the **Loki** data source at the top. Switch the query editor from **Builder** to **Code**.

Grafana Alloy collects every pod's stdout and sends it to Loki ([decision 0007](../decisions/0007-observability-stack.md)).

## 1. Select a stream with labels (2 min)

```logql
{namespace="orders-dev", app="orders-gateway"}
```

Everything inside `{}` is a **label matcher**. Loki stores logs in *streams*, one per unique set of labels, and only indexes the labels, not the text. Here there are just four: `namespace`, `app`, `env` and `pod`. Open the **Label browser** to see them.

Each line is the app's JSON log for one request:

```json
{"time":"…","level":"INFO","msg":"request","method":"POST","route":"/orders","status":201,"duration_ms":39.6,"request_id":"f978ac39-…","version":"sha-d5d3d8f966ab","order_id":"ord_8e1e5a3a43f56129"}
```

Probes (`/healthz`, `/readyz`) and Prometheus scrapes are logged at `DEBUG`, so they don't drown out the real requests.

## 2. Filter by text (2 min)

Line filters run after the label selector and scan the text:

```logql
{namespace="orders-dev", app="orders-gateway"} |= "POST"
```

- `|=` contains, `!=` doesn't contain, `|~` matches a regex, `!~` doesn't match one.
- Chain them: `|= "POST" != "\"status\":201"` shows order requests that didn't succeed.

Line filters are fast, but they're plain text: they don't know that `201` is a status code.

## 3. Parse JSON and filter on fields (3 min)

```logql
{namespace="orders-dev", app="orders-gateway"} | json | status >= 400
```

`| json` turns every JSON key into a field you can filter on, at query time. Now `status >= 400` is a number comparison. You'll see the invalid orders (`400`, about 5% of k6's traffic), logged at `WARN`.

Try a few more:

- Slow order requests: `... | json | route="/orders" | method="POST" | duration_ms > 40`
- Make the lines readable: append `| line_format "{{.method}} {{.route}} {{.status}} {{.duration_ms}}ms"`
- Errors only: `... | json | level="ERROR"`. It's empty unless the app returns 5xx, which you'll cause on purpose in exercise 4.

## 4. Follow one order (2 min)

1. Run `{namespace="orders-dev", app="orders-gateway"} | json | status = 201` and click any line to expand it. Copy its `order_id` (`ord_…`).
2. Search for that order everywhere:

   ```logql
   {namespace=~"orders-.*", app="orders-gateway"} |= "ord_8e1e5a3a43f56129"
   ```

   You'll find the `POST` that created it, across every environment and pod, without knowing in advance which pod served it. (k6's `GET /orders/{id}` requests ask for random IDs, so they won't match this one. A real client reading its order back would show up here too.) `request_id` works the same way for a single request.

This is why per-request values like order IDs and request IDs go in **logs**, not in metric or stream labels: you can search for any one of them, and they cost nothing until you do.

## 5. Turn logs into a metric (4 min)

LogQL can count and measure log lines over time, like PromQL does with samples. Switch the visualisation to **Time series**:

```logql
sum by (status) (count_over_time({namespace="orders-dev", app="orders-gateway"} | json [1m]))
```

That's requests per minute by status, counted from the logs. Compare it with Prometheus (exercise 1): `201` at about 200/min is the same as `rate(...)` at about 3.4/s (k6 at 5 req/s, 70% of them valid orders).

And a percentile from a field, with `unwrap`:

```logql
quantile_over_time(0.95, {namespace="orders-dev", app="orders-gateway"} | json | route="/orders" | method="POST" | unwrap duration_ms [5m]) by (route)
```

That's the p95 of order request time in milliseconds, computed from every log line. Compare it with the histogram estimate from exercise 1: `histogram_quantile(0.95, …http_request_duration_seconds_bucket…)` × 1000. On ogp both gave about 48 ms. The log version is exact but reads every line. The metric version is an estimate from buckets, but it's cheap, kept longer, and it's what the alerts use.

## 6. Why the labels stay few (2 min)

Every unique label set is a separate **stream**, and Loki keeps an index entry and an open chunk per stream. Count the app's streams:

```logql
count(count by (pod, namespace) (count_over_time({namespace=~"orders-.*", app="orders-gateway"}[1h])))
```

There's one per pod: a handful. If `order_id` or `request_id` were a label, every request would start a new stream, and Loki would slow down and run out of memory, the same cardinality problem as exercise 1. The rule: **labels say where a log came from** (namespace, app, pod), and **everything about the request stays in the line**, where `| json` can reach it.

## Check yourself

- Why is `|= "500"` a poor way to find server errors, and what would you write instead?
- You see a slow request in the latency panel. How do you find its log lines?
- When would you use a LogQL metric query instead of a Prometheus metric, and when not?

Next: 4. SLOs _(coming)_.
