# 2. Grafana: build a panel, then compare it to the dashboard

Time: about 15 minutes. You need a running stack and [exercise 1](01-prometheus.md).

You'll build a small dashboard with a time series panel, a stat panel and an environment drop-down, then compare it with the provided one.

## 0. Start some traffic

1. Open <http://localhost:3000> and log in as `admin` / `admin12345`.
2. In a second terminal:

   ```sh
   ./platform shell
   k6 run --quiet -e BASE_URL=http://localhost:8082 -e RATE=5 -e DURATION=15m apps/orders-gateway/app/k6/load.js
   ```

## 1. Tour the provided dashboard

Open Dashboards, then orders-gateway (<http://localhost:3000/d/orders-gateway>).

- Set environment to `dev`, where your traffic goes.
- Hover the (i) by a panel title. Every panel has a description; CI fails a dashboard without them.
- The rows go from "is it OK?" (SLO, budget, alerts) to "why not?" (traffic, latency, pods, logs). That's the order you read it in an incident.
- Pods by version uses `app_info` from exercise 1. So do the blue Version changes markers.

## 2. A time series panel

1. Go to Dashboards, New, New dashboard, Add visualization. Pick Prometheus.
2. Switch the editor from Builder to Code and enter:

   ```promql
   sum by (route) (rate(http_requests_total{namespace="dev", service="orders-gateway"}[$__rate_interval]))
   ```

   `$__rate_interval` picks a window that fits the zoom level, so you don't edit `[5m]` when you zoom out.
3. Under Options, set Legend to Custom: `{{route}}`.
4. On the right, set Title `Requests per second by route`, a one-sentence Description, and Unit `requests/sec (rps)`.
5. Save the dashboard as `My first dashboard`.

You should see about 3 req/s on `/work`, 1.5 on `/echo` and 0.5 on `/version`, plus the [background traffic](README.md#about-the-numbers).

## 3. A stat panel with thresholds

1. Add a visualization, choose Stat, and enter the latency SLI from exercise 1:

   ```promql
   sum(rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/echo|/version", le="0.25"}[$__rate_interval]))
   /
   sum(rate(http_request_duration_seconds_count{namespace="dev", route=~"/echo|/version"}[$__rate_interval]))
   ```

2. Set Unit `Percent (0.0-1.0)` and Decimals `2`.
3. Under Thresholds, make the base red and add `0.995` as green. 99.5% is the SLO.
4. Title it `Under 250 ms` and add a description.

## 4. An environment drop-down

1. Open Settings, Variables, Add variable.
2. Type Query, Name `namespace`, Label `environment`, data source Prometheus.
3. Query type Label values, Label `namespace`, Metric `app_info`. The preview lists dev, staging and prod.
4. In both panels, replace `namespace="dev"` with `namespace="$namespace"`.

The drop-down now switches both panels, as on the provided dashboard.

## 5. Compare with the provided dashboard

On the provided dashboard, open the menu of Requests per second, by route and status and choose Edit. Look, don't save.

- It sums `by (method, route, status)`, so failures and 404s show too.
- /echo and /version: share under 250 ms uses `1 - slo:orders_latency_errors:ratio_rate5m`, the recording rule from `stack/observability/alerts/`. The dashboard and the alerts compute the SLI the same way.

Leave without saving (Discard).

## 6. Where dashboards live

Grafana here has no persistent storage, so dashboards saved in the UI are lost when its pod restarts. The provided ones are JSON files in [`stack/observability/dashboards/`](../../stack/observability/dashboards/), loaded through Argo CD.

To keep yours, use Export, Export as JSON, save it in `stack/observability/dashboards/`, and follow [`stack/observability/dashboards/README.md`](../../stack/observability/dashboards/README.md).

## Check yourself

- Why `$__rate_interval` instead of `[5m]`?
- Your stat panel shows 99.7%, but Latency budget left shows 40%. How can both be true? (Hint: time windows.)
- A teammate fixed a panel in the UI yesterday; today it's back. Why, and what should they do?

Next: [3. Loki](03-loki.md).
