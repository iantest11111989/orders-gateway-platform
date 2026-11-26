# OrdersGatewayAvailabilityFastBurn

Severity: page. Act now.

More than 7.2% of `/work` and `/echo` requests in one namespace fail with a 5xx, over both the last 1 h and 5 m. That is 14.4 times the SLO budget (99.5% over 30 days), so the month's budget is gone in about 2 days. The `namespace` label is the environment (`dev`, `staging` or `prod`). Slower sibling: [OrdersGatewayAvailabilitySlowBurn](OrdersGatewayAvailabilitySlowBurn.md).

## Check

1. Find which routes, pods and versions fail (Prometheus or Grafana Explore):
   ```promql
   sum by (route, status) (rate(http_requests_total{namespace="<namespace>", service="orders-gateway", route=~"/work|/echo"}[5m]))
   sum by (pod) (rate(http_requests_total{namespace="<namespace>", service="orders-gateway", status=~"5.."}[5m]))
   app_info{namespace="<namespace>", service="orders-gateway"}
   ```
2. Read the errors in Loki:
   ```logql
   {namespace="<namespace>", app="orders-gateway"} | json | level="error"
   ```
   `"injected fault"` means a fault is switched on. Errors from one `version` mean a bad release.
3. Look for a recent change:
   ```sh
   ./platform kubectl -n <namespace> get deploy,pods -o wide
   ./platform kubectl -n <namespace> get configmap orders-gateway -o yaml | grep FAULT
   ./platform kubectl -n <namespace> rollout history deploy/orders-gateway
   ```

## Fix

- Bad release: `./pipeline rollback orders-gateway <namespace>` (add `--sync` for staging and prod). Don't use `kubectl rollout undo`: Argo CD puts Git's version back.
- Fault in config: remove `config.faultErrorRate` from `cd/orders-gateway/<namespace>.yaml` and sync.
- Fault set at runtime (`POST /admin/fault`, one pod): delete the pod. New pods start without faults:
  `./platform kubectl -n <namespace> delete pod <pod>`
- Crashing pods: `./platform kubectl -n <namespace> describe pod <pod>` and `logs <pod> --previous`. Raise the memory limit in Git for an OOM kill.

## Done when

`slo:orders_availability_errors:ratio_rate5m{namespace="<namespace>"}` stays below `0.005`, the alert resolves, and `./platform verify` passes.
