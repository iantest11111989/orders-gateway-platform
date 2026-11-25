# 1. Prometheus: your first queries

**Time:** about 15 minutes. **You need:** a running stack (`./platform up`, then `./platform verify`).

By the end you will know where the app's metrics come from, how counters and histograms differ, how to write a `rate()` query, and why the app keeps its labels to a small, fixed set.

## 0. Open Prometheus and start some traffic

1. Open <https://prometheus.localtest.me>. If the browser warns about the certificate, `./platform urls` shows how to trust the demo CA, or you can accept the warning. Prometheus has no login.
2. In a second terminal, send about 5 requests a second to dev for 10 minutes:

   ```sh
   ./platform shell
   k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders.dev.localtest.me -e RATE=5 -e DURATION=10m app/k6/load.js
   ```

   The traffic is 70% new orders, 25% order lookups and 5% invalid orders (they get a `400`). Leave it running.

## 1. Where the metrics come from (3 min)

Each `orders-gateway` pod serves its own metrics at `/metrics`. Prometheus scrapes every pod about every 30 seconds and stores each line as a time series.

1. Go to **Status → Targets** (or **Target health**) and find the `orders-gateway` job. There is one row per pod in `orders-dev`, `orders-staging` and `orders-prod`, and each should be **UP**.
2. Back on the **Query** page, run:

   ```promql
   http_requests_total{namespace="orders-dev"}
   ```

   Each result row is one series. Its labels are `route`, `method` and `code` (set by the app) plus `namespace`, `pod`, `job` and others (added by Prometheus from Kubernetes).

The app's own metrics are defined in [`app/metrics.go`](../../app/metrics.go): `http_requests_total`, `http_request_duration_seconds`, `http_requests_in_flight`, `orders_created_total`, `orders_rejected_total`, `payments_call_duration_seconds`, `payments_call_errors_total` and `app_build_info`.

## 2. Counters vs gauges vs histograms (4 min)

**Counter:** a number that only goes up (until the pod restarts and it starts again at 0). Run `orders_created_total{namespace="orders-dev"}` and switch to the **Graph** tab. You'll see a line climbing steadily. A counter's raw value means little on its own. What you want is how fast it grows.

**Gauge:** a value that goes up and down, like a reading on a meter. `http_requests_in_flight` is how many requests a pod is serving right now. `app_build_info` is a gauge that is always 1. Its labels tell you which `version` each pod runs:

```promql
app_build_info{namespace=~"orders-.*"}
```

**Histogram:** counts observations in buckets. One histogram is really three series families:

```promql
http_request_duration_seconds_bucket{namespace="orders-dev", route="/orders", method="POST"}
```

- `_bucket{le="0.3"}`: how many requests took **at most** 0.3 s. Buckets add up as they go: `le="0.5"` includes everything in `le="0.3"`, and `le="+Inf"` counts every request.
- `_count`: the number of requests, the same as the `+Inf` bucket.
- `_sum`: the total seconds spent.

The app has a bucket at exactly 0.3 s because the latency SLO is "under 300 ms". That lets the SLO be computed exactly, not estimated.

## 3. Your first `rate()` (4 min)

`rate(counter[5m])` is the per-second rate of growth over the last 5 minutes. It also handles a counter going back to 0 when a pod restarts.

1. Orders created per second in dev:

   ```promql
   sum(rate(orders_created_total{namespace="orders-dev"}[5m]))
   ```

   With k6 at 5 requests/s and 70% of them valid orders, this settles at about **3.5**. It needs a few minutes of traffic first, because the window is 5 minutes.

2. Requests per second by route and status code:

   ```promql
   sum by (route, code) (rate(http_requests_total{namespace="orders-dev"}[5m]))
   ```

   `sum by (...)` adds up all the pods and keeps only the labels you name. You should see `POST /orders` `201` (about 3.5/s), `400` (about 0.25/s, the invalid orders) and `GET /orders/{id}` (about 1.25/s). The small `/healthz`, `/readyz` and `/metrics` rates come from Kubernetes probes and Prometheus scrapes. The `503` on `/readyz` is a series that sits at 0, left over from pod startup.

3. The share of order requests that failed with a 5xx error. With no faults turned on this is 0, or empty if there has never been a 5xx:

   ```promql
   sum(rate(http_requests_total{namespace="orders-dev", route="/orders", method="POST", code=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{namespace="orders-dev", route="/orders", method="POST"}[5m]))
   ```

4. The 95th percentile (p95) latency from the histogram. Keep `le`, because `histogram_quantile` needs it:

   ```promql
   histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="orders-dev", route="/orders", method="POST"}[5m])))
   ```

   And the share of order requests that were **fast enough** for the SLO:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{namespace="orders-dev", route="/orders", method="POST", le="0.3"}[5m]))
   /
   sum(rate(http_request_duration_seconds_count{namespace="orders-dev", route="/orders", method="POST"}[5m]))
   ```

The SLO rules in [`alerts/orders-gateway-slo.yaml`](../../alerts/orders-gateway-slo.yaml) are built from these queries, saved as recording rules, with three refinements: they leave out `499` (the client gave up), they use `or 0 * ...` so a namespace that has never had a 5xx shows 0 instead of no data, and the latency rule is `1 -` the fast share, so it counts the *slow* requests. Try `slo:orders_availability_errors:ratio_rate5m`. While k6 runs, dev shows `0`. Any environment with no order traffic in the last 5 minutes shows `NaN`, because that's 0 divided by 0.

## 4. Why cardinality matters (3 min)

Every unique combination of label values is its own series, and each series costs memory in Prometheus. Count them:

```promql
count({__name__=~".+"})
```

```promql
topk(10, count by (__name__) ({__name__=~".+"}))
```

The biggest are the Kubernetes API server's histograms, at thousands of series each. Now the app:

```promql
count by (__name__) ({job="orders-gateway", __name__=~"http_.*|orders_.*"})
```

The app's metrics stay small because every label has a **fixed, short list of values**:

- `route` is the route *template* (`/orders/{id}`), never the real path. If it were `/orders/7f3a…`, every order would make a new series, and Prometheus would run out of memory.
- `orders_rejected_total` has a `reason` label from a fixed list in `app/metrics.go`, never the raw error text.
- Customer IDs, order IDs and SKUs go in the **logs** (exercise 3, Loki), not in metric labels.

Rule of thumb: if a label's values can grow without limit (IDs, emails, URLs, timestamps), it doesn't belong on a metric.

## Check yourself

- Why is `orders_created_total` on its own a poor thing to graph, and what do you graph instead?
- Your dev p95 is 0.25 s. Is that inside the SLO? Which query tells you the share of slow requests directly?
- A teammate wants to add a `customer_id` label to `http_requests_total`. What do you tell them?

Next: 2. Grafana _(coming)_.
