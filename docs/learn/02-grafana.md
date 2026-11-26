# 2. Grafana: build a panel, then compare it to the dashboard

**Time:** about 15 minutes. **You need:** a running stack and [exercise 1](01-prometheus.md), which covers the queries this exercise puts on screen.

By the end you will have built a small dashboard yourself: a time series panel, a stat panel with thresholds, and an environment drop-down. You'll also know how the provided `orders-gateway` dashboard is put together and how dashboards are kept in Git.

## 0. Log in and start some traffic

1. Open <http://localhost:3000> and log in as `admin` / `admin12345`.
2. In a second terminal, send traffic to dev for 15 minutes:

   ```sh
   ./platform shell
   k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders.dev.localtest.me -e RATE=5 -e DURATION=15m app/k6/load.js
   ```

## 1. Tour the provided dashboard (3 min)

Open **Dashboards → orders-gateway** (or <http://localhost:3000/d/orders-gateway>).

- The **environment** drop-down at the top picks the namespace. Switch it to `dev`: that's where your k6 traffic goes.
- Hover the **(i)** next to any panel title. Every panel says what it measures and why (CI refuses a panel without one).
- The rows go from "is the service OK?" (SLO, error budget, alerts) to "why not?" (traffic, latency, pods, logs). That's the order you'd read it in during an incident.
- Look at **Pods by version**. It's the same `app_info` metric you queried in exercise 1, counted per version. The blue marks on the time axis (**Version changes**) come from it too.

## 2. Build a time series panel (5 min)

1. **Dashboards → New → New dashboard → Add visualization**, and pick the **Prometheus** data source.
2. In the query editor switch from **Builder** to **Code**, and enter:

   ```promql
   sum by (route) (rate(http_requests_total{namespace="dev", route=~"/work|/echo|/version"}[$__rate_interval]))
   ```

   `$__rate_interval` is a Grafana variable. It picks a `rate()` window that fits the zoom level and the scrape interval, so you don't have to change `[5m]` by hand when you zoom out to a day.
3. Under the query, open **Options** and set **Legend** to **Custom**: `{{route}}`. The lines are now called `/work`, `/echo` and `/version`, not the full label set.
4. In the panel options on the right:
   - **Title:** `Requests per second by route`
   - **Description:** write one sentence that says what it shows (for example, "Requests per second to each of the app's routes in dev, all statuses").
   - **Standard options → Unit:** `requests/sec (rps)`
5. **Back to dashboard**, then save it (the disk icon) as `My first dashboard`.

You should see `/work` at about 3 req/s, `/echo` at about 1.5 and `/version` at about 0.5, plus the trickle's share on `/work` and `/echo` (see [the README here](README.md)).

## 3. A stat panel with thresholds (3 min)

Add another visualization, choose **Stat** (top right), and enter:

```promql
sum(rate(http_request_duration_seconds_bucket{namespace="dev", route=~"/echo|/version", le="0.25"}[$__rate_interval]))
/
sum(rate(http_request_duration_seconds_count{namespace="dev", route=~"/echo|/version"}[$__rate_interval]))
```

That's the share of `/echo` and `/version` requests faster than 250 ms, the latency SLI from exercise 1. Then:

- **Unit:** `Percent (0.0-1.0)`. **Decimals:** `2`.
- **Thresholds:** set the base colour to **red** and add a step at `0.995` coloured **green**. 99.5% is the SLO.
- **Title:** `Under 250 ms`, plus a description.

The panel is green while the app meets the latency SLO. In exercise 4 you'll make it go red on purpose.

## 4. Add an environment drop-down (2 min)

Hard-coding `dev` means one dashboard per environment. Use a variable instead:

1. **Edit → Settings → Variables → Add variable**.
2. **Type:** Query. **Name:** `namespace`. **Label:** `environment`. **Data source:** Prometheus.
3. **Query type:** Label values. **Label:** `namespace`. **Metric:** `app_info`. The preview lists `dev`, `prod` and `staging`, plus any namespace a demo used in the last 24 hours (such as `demo`): Prometheus still has those series.
4. Back on the dashboard, edit both panels and replace `namespace="dev"` with `namespace="$namespace"`.

Now the drop-down switches both panels between environments, the same way the provided dashboard works.

## 5. Compare with the provided dashboard (2 min)

Open the provided `orders-gateway` dashboard and, on **Requests per second, by route and status**, choose **⋮ → Edit** (look, don't save). Compare it with your panel:

- It sums `by (method, route, status)`, so you also see failures and the caller's mistakes (`GET /echo` is a 404).
- It needs no filter for probes and scrapes: the app doesn't count `/healthz`, `/readyz` or `/metrics`, and the scrape drops unknown paths.
- **/echo and /version: share under 250 ms** uses `1 - slo:orders_latency_errors:ratio_rate5m`. That's the recording rule from `alerts/`, so the dashboard and the alerts compute the SLI the same way, and Prometheus does the work once.

Leave without saving. If Grafana asks, **Discard**.

## 6. Where dashboards really live

Grafana here has no persistent storage: **dashboards you save in the UI are gone when the Grafana pod restarts.** The provided dashboards come from Git. Each is a JSON file in [`dashboards/`](../../dashboards/), turned into a ConfigMap that Argo CD applies and Grafana's sidecar loads.

To keep yours, use **Export → Export as JSON** on your dashboard, save it as `dashboards/my-first.json`, and follow the steps in [`dashboards/README.md`](../../dashboards/README.md). `scripts/dashboards.sh check` would then refuse it if you skipped a description.

## Check yourself

- Why `$__rate_interval` instead of a fixed `[5m]`?
- Your stat panel is green at 99.7% but the provided **Latency budget left** shows 40%. How can both be true? (Hint: different time windows.)
- A teammate fixed a panel in the Grafana UI yesterday and today it's back to the old version. What happened, and what should they do instead?

Next: [3. Loki](03-loki.md).
