# 1. Prometheus: your first queries

**Time:** about 15 minutes. **You need:** a running stack (`docker compose up -d --wait`, then `./platform verify`).

By the end you will know where the app's metrics come from, how counters and histograms differ, how to write a `rate()` query, and why the app's metrics stay small.

## 0. Open Prometheus and start some traffic

1. Open <http://localhost:9090>. Prometheus has no login.
2. In a second terminal, send about 5 requests a second to dev for 10 minutes:

   ```sh
   ./platform shell
   k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders.dev.localtest.me -e RATE=5 -e DURATION=10m app/k6/load.js
   ```

   The traffic is 60% `GET /work?ms=10..50` (the app burns that much CPU), 30% `POST /echo` and 10% `GET /version`. Leave it running.

## 1. Where the metrics come from (3 min)

Each app pod serves its own metrics at `/metrics` ([`app/server.js`](../../app/server.js) writes them by hand, no library). Prometheus scrapes every pod about every 30 seconds and stores each line as a time series.

1. Go to **Status → Targets** (or **Target health**) and find the `app` job. There is one row per pod in `dev`, `staging` and `prod`, and each should be **UP**.
2. Back on the **Query** page, run:

   ```promql
   http_requests_total{namespace="dev"}
   ```

   Each result row is one series. Its labels are `route`, `method` and `status` (set by the app) plus `namespace`, `pod`, `job` and others (added by Prometheus from Kubernetes).

The app exports five metrics: `http_requests_total`, `http_request_duration_seconds`, `app_inflight_requests`, `app_ready` and `app_info`. It doesn't count its own probes and scrapes (`/healthz`, `/readyz`, `/metrics`), so everything you see is real traffic.

## 2. Counters vs gauges vs histograms (4 min)

**Counter:** a number that only goes up (until the pod restarts and it starts again at 0). Run `http_requests_total{namespace="dev", route="/echo"}` and switch to the **Graph** tab. You'll see lines climbing steadily. A counter's raw value means little on its own. What you want is how fast it grows.

**Gauge:** a value that goes up and down, like a reading on a meter. `app_inflight_requests` is how many requests a pod is handling right now, and `app_ready` is 1 when the pod would answer `/readyz` with 200. `app_info` is a gauge that is always 1. Its label tells you which `version` each pod runs:

```promql
app_info{namespace=~"dev|staging|prod"}
```

**Histogram:** counts observations in buckets. One histogram is really three series families:

```promql
http_request_duration_seconds_bucket{namespace="dev", route="/echo"}
```

- `_bucket{le="0.25"}`: how many requests took **at most** 0.25 s. Buckets add up as they go: `le="0.5"` includes everything in `le="0.25"`, and `le="+Inf"` counts every request.
- `_count`: the number of requests, the same as the `+Inf` bucket.
- `_sum`: the total seconds spent.

The app's buckets are 5, 10, 25, 50, 100, 250, 500 ms, 1, 2.5 and 5 s. The latency SLO uses 250 ms because that's a bucket edge, so the share of slow requests is counted exactly, not estimated. Note the histogram has only a `route` label, no `method` and no `status`.

## 3. Your first `rate()` (4 min)

`rate(counter[5m])` is the per-second rate of growth over the last 5 minutes. It also handles a counter going back to 0 when a pod restarts.

1. Requests per second in dev, by route:

   ```promql
   sum by (route) (rate(http_requests_total{namespace="dev"}[5m]))
   ```

   With k6 at 5 requests/s this settles at about **3** for `/work`, **1.5** for `/echo` and **0.5** for `/version`, plus the trickle (see [the README here](README.md)). It needs a few minutes of traffic first, because the window is 5 minutes.

2. Requests per second by route and status:

   ```promql
   sum by (route, method, status) (rate(http_requests_total{namespace="dev"}[5m]))
   ```

   `sum by (...)` adds up all the pods and keeps only the labels you name. Everything should be `200`. Try `curl -sk https://orders.dev.localtest.me/echo` (a `GET`, which `/echo` doesn't serve) a few times and a `404` series appears.

3. The share of `/work` and `/echo` requests that failed with a 5xx. With no faults turned on this is 0, or empty if there has never been a 5xx:

   ```promql
   sum(rate(http_requests_total{namespace="dev", route=~"/work|/echo", status=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{namespace="dev", route=~"/work|/echo"}[5m]))
   ```

4. The 95th percentile (p95) latency from the histogram. Keep `le`, because `histogram_quantile` needs it. Compare `/work` with `/echo`:

   ```promql
   histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/work|/echo"}[5m])))
   ```

   `/work` sits near 50 ms because k6 asks for 10 to 50 ms of CPU. That's the caller's choice, which is why the latency SLO leaves `/work` out. And the share of `/echo` and `/version` requests that were **fast enough** for the SLO:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/echo|/version", le="0.25"}[5m]))
   /
   sum(rate(http_request_duration_seconds_count{namespace="dev", route=~"/echo|/version"}[5m]))
   ```

The SLO rules in [`alerts/orders-gateway-slo.yaml`](../../alerts/orders-gateway-slo.yaml) are built from these queries, saved as recording rules, with three refinements: they leave out `4xx` (the caller's mistake), they use `or 0 * ...` so a namespace that has never had a 5xx shows 0 instead of no data, and the latency rule is `1 -` the fast share, so it counts the *slow* requests. Try `slo:orders_availability_errors:ratio_rate5m`. While traffic flows, dev shows `0`.

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
count by (__name__) ({job="app", __name__=~"http_.*|app_.*"})
```

The app's metrics stay small, but not by the app's own doing. Its `route` label is the raw path for any path it doesn't know, so a scanner trying `/wp-login.php`, `/.env`, `/a1`, `/a2`, ... would create a new series for each. Try it:

```sh
for i in 1 2 3; do curl -sk -o /dev/null https://orders.dev.localtest.me/nope-$i; done
```

Then look for them: `http_requests_total{namespace="dev", route=~"/nope.*"}` returns nothing. The ServiceMonitor keeps only the app's own routes (`/work`, `/echo`, `/version`, `/admin`) and drops the rest at scrape time. The 404s still show in the logs (exercise 3, Loki) and in Envoy's metrics.

Rule of thumb: if a label's values can grow without limit (IDs, emails, raw URLs, timestamps), it doesn't belong on a metric. Per-request values like `trace_id` go in the logs.

## Check yourself

- Why is `http_requests_total` on its own a poor thing to graph, and what do you graph instead?
- Your dev `/work` p95 is 1.8 s. Is the latency SLO in trouble? What would you look at first?
- Why does the scrape *drop* unknown routes instead of renaming them all to `route="other"`? (Hint: two different paths, both `GET 404`.)

Next: [2. Grafana](02-grafana.md).
