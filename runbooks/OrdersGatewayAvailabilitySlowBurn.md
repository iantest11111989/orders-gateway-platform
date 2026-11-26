# OrdersGatewayAvailabilitySlowBurn

**Severity: ticket.** Not an emergency, but look at it today. Left alone, it uses up the month's budget.

## What it means

The orders-gateway availability SLO says 99.5% of `/work` and `/echo` requests must not fail with a 5xx, over 30 days. That leaves an **error budget of 0.5%**. 4xx answers (a `GET /echo`, say) are the caller's mistake and count as neither good nor bad. This alert covers the **availability** SLI.

It fires when more than **3%** of `/work` and `/echo` requests in one namespace (environment) fail with a 5xx status. That's **6x** the rate the budget allows, measured over the last **6 hours** and also over the last **30 minutes**, for 15 minutes. At that rate the 30-day error budget would be gone in about 5 days.

The short window lets the alert clear soon after the problem is fixed, instead of waiting for the long window to forget it. Its faster sibling is [OrdersGatewayAvailabilityFastBurn](OrdersGatewayAvailabilityFastBurn.md).

The alert's `namespace` label tells you which environment it is. Use it for `<namespace>` below; `<env>` is the matching folder in `environments/`.

## Likely causes

- **A bad release.** A new version returns 5xx. It shows as errors from one `version` (the log lines carry it, and `app_info` says which pods run it).
- **Injected faults:** 500s with `"injected fault"`. Someone set `FAULT_ERROR_RATE` (the environment's `config.faultErrorRate`), or called `POST /admin/fault` from inside the cluster. A runtime fault lives in one pod's memory and is gone when that pod restarts.
- **Pods crashing or not ready**, which overloads the remaining pods.

## How to check

1. **How bad, and where?** In Prometheus (http://localhost:9090) or Grafana Explore:
   ```promql
   # Error ratio per window (the SLO allows 0.005 = 0.5%)
   slo:orders_availability_errors:ratio_rate5m{namespace="<namespace>"}
   slo:orders_availability_errors:ratio_rate1h{namespace="<namespace>"}

   # Which routes and status codes?
   sum by (route, status) (rate(http_requests_total{namespace="<namespace>", route=~"/work|/echo"}[5m]))

   # One pod (a runtime fault) or version, or all of them?
   sum by (pod) (rate(http_requests_total{namespace="<namespace>", route=~"/work|/echo", status=~"5.."}[5m]))
   app_info{namespace="<namespace>"}
   ```
2. **What do the failing requests say?** In Grafana Explore, choose Loki:
   ```logql
   {namespace="<namespace>", app="app"} | json | level="error"

   # Errors per minute by pod and version
   sum by (pod, version) (count_over_time({namespace="<namespace>", app="app"} | json | status >= 500 [1m]))
   ```
   A request sent with a `traceparent` header logs its `trace_id`: search for it to follow that request.
3. **Did something just change?**
   ```sh
   ./platform kubectl -n <namespace> get deploy,pods -o wide
   ./platform kubectl -n <namespace> get configmap app -o yaml | grep FAULT   # the app's settings (envFrom)
   ./platform kubectl -n <namespace> rollout history deploy/app              # recent revisions
   ```
   Check the Argo CD UI for a recent sync of this environment.

## How to fix

- **Bad release:** roll back through Git, so Argo CD doesn't undo it. In the default setup, `./platform rollback --env <env>` puts back the image `<env>` ran before (README, Roll back); it pushes a commit to the in-stack Git server and waits for the rollout. When Argo CD syncs from GitHub, revert the image change in `environments/<env>/values.yaml` with a pull request instead. Don't `kubectl rollout undo`: self-heal puts Git's version back within seconds.
- **Injected faults:** remove `config.faultErrorRate` from the environment's values and let Argo CD sync. For a runtime fault, reset it from inside the cluster (`POST /admin/fault` with `{"error_rate": 0}` to each pod), or delete the pods: they start clean.
- **Crashing pods:** run `./platform kubectl -n <namespace> describe pod <pod>` and `logs --previous`, then fix the cause. For an OOM kill, raise the memory limit. For a failing probe, check `/readyz` (503 for the first 3 s, and while draining).

Always fix through Git. Argo CD's self-heal reverts a manual `kubectl edit`.

## How to verify recovery

- `slo:orders_availability_errors:ratio_rate5m{namespace="<namespace>"}` drops below `0.005` and stays there.
- The alert resolves in Alertmanager (http://localhost:9093). Allow up to half an hour, because the 30-minute window has to clear.
- The burn rate on the orders-gateway Grafana dashboard is back under 1.
- `./platform verify` passes.
