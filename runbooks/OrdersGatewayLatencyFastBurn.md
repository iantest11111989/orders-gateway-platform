# OrdersGatewayLatencyFastBurn

Severity: page. Act now.

More than 7.2% of `/echo` and `/version` requests in one namespace take over 250 ms, over both the last 1 h and 5 m. That is 14.4 times the SLO budget, so the month's budget is gone in about 2 days. `/work` is not in this SLI. The `namespace` label is the environment. Slower sibling: [OrdersGatewayLatencySlowBurn](OrdersGatewayLatencySlowBurn.md).

## Check

1. See how slow, and whether pods are saturated:
   ```promql
   histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="<namespace>", service="orders-gateway", route=~"/echo|/version"}[5m])))
   sum by (pod) (app_inflight_requests{namespace="<namespace>", service="orders-gateway"})
   sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="<namespace>", container="orders-gateway"}[5m]))
   ```
2. Look for large `/work` calls in Loki. They burn CPU on the single event loop and hold up every other request on that pod:
   ```logql
   {namespace="<namespace>", app="orders-gateway"} | json | route="/work" | duration_ms > 500
   ```
3. Look for a recent change, and whether the HPA is at its maximum (6 in prod):
   ```sh
   ./platform kubectl -n <namespace> get deploy,hpa,pods -o wide
   ./platform kubectl -n <namespace> rollout history deploy/orders-gateway
   ./platform kubectl top pods -n <namespace>
   ```

## Fix

- Bad release (slow on one `version`): `./pipeline rollback orders-gateway <namespace>` (add `--sync` for staging and prod).
- Saturation: raise `autoscaling.maxReplicas` or the CPU request in `cd/orders-gateway/<namespace>.yaml`. Check `./platform budget` first: the stack must stay within 6 CPU / 12 GiB.
- `config.faultLatencyMs` delays only `/work`, so it does not cause this alert on its own.

## Done when

`slo:orders_latency_errors:ratio_rate5m{namespace="<namespace>"}` stays below `0.005`, the alert resolves, and `./platform verify` passes.
