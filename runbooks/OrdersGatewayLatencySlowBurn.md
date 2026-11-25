# OrdersGatewayLatencySlowBurn

**Severity: ticket.** Not an emergency, but look at it today. Left alone, it uses up the month's budget.

## What it means

The orders-gateway latency SLO says 99.5% of `/echo` and `/version` requests must finish within 250 ms (the histogram's `le="0.25"` bucket), over 30 days. That leaves an **error budget of 0.5%**. `/work` is left out: its latency is whatever the caller asks for with `?ms=` ([decision 0027](../docs/decisions/0027-slis-for-the-node-app.md)). This alert covers the **latency** SLI.

It fires when more than **3%** of `/echo` and `/version` requests in one namespace (environment) take longer than 250 ms. That's **6x** the rate the budget allows, measured over the last **6 hours** and also over the last **30 minutes**, for 15 minutes. At that rate the 30-day error budget would be gone in about 5 days.

The short window lets the alert clear soon after the problem is fixed, instead of waiting for the long window to forget it. Its faster sibling is [OrdersGatewayLatencyFastBurn](OrdersGatewayLatencyFastBurn.md).

The alert's `namespace` label tells you which environment it is. Use it for `<namespace>` below; `<env>` is the matching folder in `environments/`.

## Likely causes

- **A bad release** that is slower. It shows on one `version`.
- **Injected latency:** someone set `FAULT_LATENCY_MS` (the environment's `config.faultLatencyMs`), or called `POST /admin/fault` from inside the cluster. Note it delays `/work`, not `/echo`, so it shows here only through saturation.
- **Saturation.** `/work` burns CPU on the app's single event loop, so long `/work` calls hold up every other request on that pod, `/echo` included. Look for requests in flight piling up, the HPA at its maximum (6 in prod), or a node short of CPU.

## How to check

1. **How slow, and where?** In Prometheus (http://localhost:9090) or Grafana Explore:
   ```promql
   # Share of /echo and /version slower than 250 ms (the SLO allows 0.005 = 0.5%)
   slo:orders_latency_errors:ratio_rate5m{namespace="<namespace>"}
   slo:orders_latency_errors:ratio_rate1h{namespace="<namespace>"}

   # p99 and p50 latency of the SLI's routes, and of /work for comparison
   histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", route=~"/echo|/version"}[5m])))
   histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", route=~"/echo|/version"}[5m])))
   histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", route="/work"}[5m])))

   # Saturation: requests in flight and CPU use per pod
   sum by (pod) (app_inflight_requests{namespace="<namespace>"})
   sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="<namespace>", container="orders-gateway"}[5m]))
   ```
2. **Which requests are slow?** In Grafana Explore, choose Loki:
   ```logql
   {namespace="<namespace>", app="app"} | json | route=~"/echo|/version" | duration_ms > 250

   # Slow requests per minute by pod and version
   sum by (pod, version) (count_over_time({namespace="<namespace>", app="app"} | json | route=~"/echo|/version" | duration_ms > 250 [1m]))

   # Big /work calls around the same time (the usual cause of slow /echo)
   {namespace="<namespace>", app="app"} | json | route="/work" | duration_ms > 500
   ```
3. **Did something just change?**
   ```sh
   ./platform kubectl -n <namespace> get deploy,hpa,pods -o wide
   ./platform kubectl -n <namespace> describe deploy app | grep -iE 'image|FAULT|requests|limits' -A1
   ./platform kubectl top pods -n <namespace>
   ```

## How to fix

- **Bad release:** roll back through Git, so Argo CD doesn't undo it. In the default setup, `./platform rollback --env <env>` puts back the image `<env>` ran before (README, Roll back); it pushes a commit to the in-stack Git server and waits for the rollout. When Argo CD syncs from GitHub, revert the image change in `environments/<env>/values.yaml` with a pull request instead. Don't `kubectl rollout undo`: self-heal puts Git's version back within seconds.
- **Injected latency:** remove `config.faultLatencyMs` from the environment's values and let Argo CD sync; for a runtime fault, delete the pods (they start clean).
- **Saturation:** raise the HPA maximum or the CPU request in the environment's values, or find what else is using the node. Check `./platform budget` first, because the stack must stay within 6 CPU / 12 GB.

Always fix through Git. Argo CD's self-heal reverts a manual `kubectl edit`.

## How to verify recovery

- `slo:orders_latency_errors:ratio_rate5m{namespace="<namespace>"}` drops below `0.005` and stays there.
- The alert resolves in Alertmanager (http://localhost:9093). Allow up to half an hour, because the 30-minute window has to clear.
- The burn rate on the orders-gateway Grafana dashboard is back under 1.
- `./platform verify` passes.
