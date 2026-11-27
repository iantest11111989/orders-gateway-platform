# 1. Prometheus: your first queries

Time: about 15 minutes. You need a running stack.

You'll learn where the app's metrics come from, how counters and histograms differ, how to use `rate()`, and why the app's metrics stay small.

## 0. Start some traffic

1. Open Prometheus at <http://localhost:9090>.
2. In a second terminal, send 5 requests a second to dev for 10 minutes:

   ```sh
   ./platform shell
   k6 run --quiet -e BASE_URL=http://localhost:8082 -e RATE=5 -e DURATION=10m apps/orders-gateway/app/k6/load.js
   ```

   The mix is 60% `GET /work`, 30% `POST /echo` and 10% `GET /version`. Leave it running.

## 1. Where the metrics come from

Each pod serves `/metrics`, written by hand in [`server.js`](../../apps/orders-gateway/app/server.js). Prometheus scrapes every pod every 30 seconds.

1. Open Status, then Targets. Find the `orders-gateway` targets: one per pod in dev, staging and prod, all UP.
2. On the Query page, run:

   ```promql
   http_requests_total{namespace="dev", service="orders-gateway"}
   ```

   Each row is one series. The app sets `route`, `method` and `status`. Prometheus adds `namespace`, `pod`, `service` and others.

The app doesn't count its own probes or scrapes, so every request you see is real traffic.

## 2. Counters, gauges, histograms

- Counter: only goes up. Graph `http_requests_total{namespace="dev", route="/echo"}` and you get climbing lines. The raw value means little; you want how fast it grows.
- Gauge: goes up and down. `app_inflight_requests` is requests in progress. `app_info` is always 1, and its `version` label says what each pod runs.
- Histogram: counts requests into latency buckets. Run:

  ```promql
  http_request_duration_seconds_bucket{namespace="dev", route="/echo"}
  ```

  `le="0.25"` counts requests that took at most 0.25 s. Buckets are cumulative, and `le="+Inf"` counts all of them. `_count` and `_sum` hold the total requests and total seconds.

The latency SLO uses 250 ms because it's a bucket edge, so slow requests are counted exactly.

## 3. Your first `rate()`

`rate(counter[5m])` is the per-second increase over the last 5 minutes. It handles counters resetting when a pod restarts.

1. Requests per second by route:

   ```promql
   sum by (route) (rate(http_requests_total{namespace="dev"}[5m]))
   ```

   After a few minutes: about 3 for `/work`, 1.5 for `/echo` and 0.5 for `/version`, plus the [background traffic](README.md#about-the-numbers).

2. Add status. Then run `curl -s http://localhost:8082/echo` a few times (a `GET`, which `/echo` doesn't serve) and watch a `404` series appear:

   ```promql
   sum by (route, method, status) (rate(http_requests_total{namespace="dev"}[5m]))
   ```

3. The share of `/work` and `/echo` failing with a 5xx. It's 0, or empty if there has never been one:

   ```promql
   sum(rate(http_requests_total{namespace="dev", route=~"/work|/echo", status=~"5.."}[5m]))
   /
   sum(rate(http_requests_total{namespace="dev", route=~"/work|/echo"}[5m]))
   ```

4. p95 latency. Keep `le` in the `sum`, because `histogram_quantile` needs it:

   ```promql
   histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/work|/echo"}[5m])))
   ```

   `/work` sits near 50 ms because k6 asks for 10 to 50 ms of CPU. The caller picks that, so the latency SLO leaves `/work` out.

5. The share of `/echo` and `/version` faster than 250 ms:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/echo|/version", le="0.25"}[5m]))
   /
   sum(rate(http_request_duration_seconds_count{namespace="dev", route=~"/echo|/version"}[5m]))
   ```

The SLO recording rules in [`stack/observability/alerts/orders-gateway-slo.yaml`](../../stack/observability/alerts/orders-gateway-slo.yaml) are these queries, saved. Try `slo:orders_availability_errors:ratio_rate5m`.

## 4. Cardinality

Every unique set of label values is a separate series, and each costs memory.

1. Count all series, then the biggest metrics:

   ```promql
   count({__name__=~".+"})
   ```

   ```promql
   topk(10, count by (__name__) ({__name__=~".+"}))
   ```

2. Now hit some unknown paths:

   ```sh
   for i in 1 2 3; do curl -s -o /dev/null http://localhost:8082/nope-$i; done
   ```

3. Look for them: `http_requests_total{namespace="dev", route=~"/nope.*"}` returns nothing.

The app reports any unknown path as its own `route`, so a scanner could create thousands of series. The [ServiceMonitor](../../apps/orders-gateway/chart/templates/servicemonitor.yaml) keeps only `/work`, `/echo`, `/version` and `/admin` and drops the rest. The 404s still show in the logs (exercise 3).

Rule of thumb: a label whose values can grow without limit (IDs, raw URLs) doesn't belong on a metric.

## Check yourself

- Why graph `rate(http_requests_total[5m])` and not `http_requests_total`?
- dev's `/work` p95 is 1.8 s. Is the latency SLO in trouble?
- Why drop unknown routes instead of renaming them all to `route="other"`? (Hint: two paths, both `GET 404`, in one scrape.)

Next: [2. Grafana](02-grafana.md).
