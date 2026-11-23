# OrdersGatewayLatencySlowBurn

**Severity: ticket.** Not an emergency, but look at it today. Left alone, it uses up the month's budget.

## What it means

The orders-gateway SLO says 99.5% of `POST /orders` requests must succeed (non-5xx) **and** finish in under 300 ms, over 30 days. That leaves an **error budget of 0.5%**. This alert covers the **latency** half of the SLO.

It fires when more than **3%** of `POST /orders` requests in one namespace (environment) take longer than 300 ms. That's **6x** the rate the budget allows, measured over the last **6 hours** and also over the last **30 minutes**, for 15 minutes. At that rate the 30-day error budget would be gone in about 5 days.

The short window lets the alert clear soon after the problem is fixed, instead of waiting for the long window to forget it. Its faster sibling is [OrdersGatewayLatencyFastBurn](OrdersGatewayLatencyFastBurn.md).

The alert's `namespace` label tells you which environment it is. Use it for `<namespace>` below; `<env>` is the matching folder in `environments/`.

## Likely causes

- **A bad release** that is slower. It often shows on one `version` or on canary pods only.
- **A slow payments dependency:** `payments_call_duration_seconds` p99 near or above 300 ms. In this demo that's `PAYMENTS_LATENCY_MS`.
- **Injected latency:** someone set `FAULT_LATENCY_MS`, as in the `docs/learn/` SLO exercise.
- **Saturation:** CPU throttling at the pod limit, the HPA at its maximum (6 in prod), or a node under memory pressure.

## How to check

1. **How slow, and where?** In Prometheus (`https://prometheus.localtest.me`) or Grafana Explore:
   ```promql
   # Share of requests slower than 300 ms (the SLO allows 0.005 = 0.5%)
   slo:orders_latency_errors:ratio_rate5m{namespace="<namespace>"}
   slo:orders_latency_errors:ratio_rate1h{namespace="<namespace>"}

   # p99 and p50 latency of POST /orders
   histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", route="/orders", method="POST"}[5m])))
   histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", route="/orders", method="POST"}[5m])))

   # Is the time spent waiting on payments?
   histogram_quantile(0.99, sum by (le) (rate(payments_call_duration_seconds_bucket{namespace="<namespace>"}[5m])))

   # Saturation: requests in flight, and the share of CPU periods throttled, per pod
   sum by (pod) (http_requests_in_flight{namespace="<namespace>"})
   sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="<namespace>", container="orders-gateway"}[5m]))
     / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="<namespace>", container="orders-gateway"}[5m]))
   ```
2. **Which requests are slow?** In Grafana Explore, choose Loki:
   ```logql
   {namespace="<namespace>", app="orders-gateway"} | json | route="/orders" | duration_ms > 300

   # Slow requests per minute by version (is it the canary?)
   sum by (version) (count_over_time({namespace="<namespace>", app="orders-gateway"} | json | route="/orders" | duration_ms > 300 [1m]))
   ```
3. **Did something just change?**
   ```sh
   ./platform kubectl -n <namespace> get deploy,rollout,hpa,pods -o wide
   ./platform kubectl -n <namespace> describe deploy orders-gateway | grep -iE 'image|FAULT|PAYMENTS|limits' -A1
   ./platform kubectl top pods -n <namespace>
   ```

## How to fix

- **Bad release:** roll back. In prod, run `./platform kubectl argo rollouts -n <namespace> abort orders-gateway`, then revert the image change in `environments/<env>/values.yaml` with a pull request.
- **Slow payments:** there is nothing to fix in orders-gateway. In the demo, remove `PAYMENTS_LATENCY_MS` from the environment's values.
- **Injected latency:** remove `FAULT_LATENCY_MS` from the environment's values and let Argo CD sync.
- **Saturation:** raise the CPU limit or the HPA maximum in the environment's values, or find what else is using the node. Check `./platform budget` first, because the stack must stay within 6 CPU / 12 GB.

Always fix through Git. Argo CD's self-heal reverts a manual `kubectl edit`.

## How to verify recovery

- `slo:orders_latency_errors:ratio_rate5m{namespace="<namespace>"}` drops below `0.005` and stays there.
- The alert resolves in Alertmanager (`https://alertmanager.localtest.me`). Allow up to half an hour, because the 30-minute window has to clear.
- The burn rate on the orders-gateway Grafana dashboard is back under 1.
- `./platform verify` passes.
