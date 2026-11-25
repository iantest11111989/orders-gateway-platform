# OrdersGatewayAvailabilityFastBurn

**Severity: page.** Act now: users are seeing this.

## What it means

The orders-gateway SLO says 99.5% of `POST /orders` requests must succeed (non-5xx) **and** finish in under 300 ms, over 30 days. That leaves an **error budget of 0.5%**. This alert covers the **availability** half of the SLO.

It fires when more than **7.2%** of `POST /orders` requests in one namespace (environment) fail with a 5xx status. That's **14.4x** the rate the budget allows, measured over the last **1 hour** and also over the last **5 minutes**, for 2 minutes. At that rate the whole 30-day error budget would be gone in about 2 days.

The short window lets the alert clear soon after the problem is fixed, instead of waiting for the long window to forget it. Its slower sibling is [OrdersGatewayAvailabilitySlowBurn](OrdersGatewayAvailabilitySlowBurn.md).

Requests that the client abandoned (status **499**) count as neither good nor bad. See [decision 0006](../docs/decisions/0006-slo-rules.md).

The alert's `namespace` label tells you which environment it is. Use it for `<namespace>` below; `<env>` is the matching folder in `environments/`.

## Likely causes

- **A bad release.** A new version returns 5xx. It often shows as errors from one `version` or from canary pods only. In prod, Argo Rollouts' analysis should abort the canary by itself.
- **The payments dependency is failing:** 502s, with `payments_call_errors_total` rising. In this demo that's `PAYMENTS_ERROR_RATE`.
- **Injected faults:** 500s with `"injected fault"`. Someone set `FAULT_ERROR_RATE`, as in the `docs/learn/` SLO exercise.
- **Pods crashing or not ready**, which overloads the remaining pods.

## How to check

1. **How bad, and where?** In Prometheus (`https://prometheus.localtest.me`) or Grafana Explore:
   ```promql
   # Error ratio per window (the SLO allows 0.005 = 0.5%)
   slo:orders_availability_errors:ratio_rate5m{namespace="<namespace>"}
   slo:orders_availability_errors:ratio_rate1h{namespace="<namespace>"}

   # Which status codes? 502 = payments dependency, 500 = app error or injected fault
   sum by (code) (rate(http_requests_total{namespace="<namespace>", route="/orders", method="POST"}[5m]))

   # One pod or version (a canary), or all of them?
   sum by (pod) (rate(http_requests_total{namespace="<namespace>", route="/orders", method="POST", code=~"5.."}[5m]))
   app_build_info{namespace="<namespace>"}

   # Is the payments dependency failing?
   rate(payments_call_errors_total{namespace="<namespace>"}[5m])
   ```
2. **What do the failing requests say?** In Grafana Explore, choose Loki:
   ```logql
   {namespace="<namespace>", app="app"} | json | level="ERROR"

   # Errors per minute by status and version
   sum by (status, version) (count_over_time({namespace="<namespace>", app="app"} | json | status >= 500 [1m]))
   ```
   Copy a `request_id` from a failing line and search for it to see that request's whole story.
3. **Did something just change?**
   ```sh
   ./platform kubectl -n <namespace> get deploy,pods -o wide
   ./platform kubectl -n <namespace> get configmap app -o yaml | grep -E 'FAULT|PAYMENTS'   # the app's settings (it reads them with envFrom)
   ./platform kubectl -n <namespace> rollout history deploy/app   # recent revisions
   ```
   Check the Argo CD UI (`https://argocd.localtest.me`) for a recent sync of this environment.

## How to fix

- **Bad release:** roll back. Run `./platform kubectl -n <namespace> rollout undo deploy/app`, which rolls the pods back to the previous version at once (Argo CD's self-heal puts Git's version back within minutes, so this buys time, it doesn't replace the fix). Then revert the image change in `environments/<env>/values.yaml` with a pull request, so Git matches.
- **Payments failing:** there is nothing to fix in orders-gateway. The 502s are its honest answer. Fix the dependency or wait for it. In the demo, remove `PAYMENTS_ERROR_RATE` from the environment's values.
- **Injected faults:** remove `FAULT_ERROR_RATE` from the environment's values and let Argo CD sync.
- **Crashing pods:** run `./platform kubectl -n <namespace> describe pod <pod>` and `logs --previous`, then fix the cause. For an OOM kill, raise the memory limit. For a failing probe, check `/readyz`.

Always fix through Git. Argo CD's self-heal reverts a manual `kubectl edit`.

## How to verify recovery

- `slo:orders_availability_errors:ratio_rate5m{namespace="<namespace>"}` drops below `0.005` and stays there.
- The alert resolves in Alertmanager (`https://alertmanager.localtest.me`).
- The burn rate on the orders-gateway Grafana dashboard is back under 1.
- `./platform verify` passes.
