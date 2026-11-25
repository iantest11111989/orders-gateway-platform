# 4. SLOs: break the app, watch the error budget burn

**Time:** about 20 minutes, most of it waiting for windows to fill. **You need:** a running stack and exercises [1](01-prometheus.md) to [3](03-loki.md).

By the end you will have made the app fail on purpose, watched its error budget burn and the burn-rate alert fire, followed the runbook to the cause, fixed it, and watched the alert clear. You'll also know why the alert uses two windows.

## The SLO in one paragraph

99.5% of `POST /orders` requests must succeed (not 5xx) and finish in under 300 ms, over 30 days. The 0.5% that may fail is the **error budget**. The **burn rate** is how fast you're spending it: 1 means on pace to spend exactly the budget in 30 days, 14.4 means it's gone in about 2 days. `OrdersGatewayAvailabilityFastBurn` pages when the burn rate is over 14.4 (7.2% of requests failing) over the last **1 hour** *and* the last **5 minutes**, for 2 minutes. The rules are in [`alerts/orders-gateway-slo.yaml`](../../alerts/orders-gateway-slo.yaml), and [decision 0006](../decisions/0006-slo-rules.md) explains them.

## 0. A copy of dev to break (3 min)

Never break the real environments. Make a copy in `orders-demo` the way the demos do ([decision 0020](../decisions/0020-demos-in-a-copy-of-prod.md)):

```sh
./platform demo rolling-update --keep
```

This takes about 2 minutes and leaves an Argo CD Application `orders-demo`, a copy of dev, running at `https://orders-demo.localtest.me`.

Open the **orders-gateway** dashboard in Grafana and set **environment** to `orders-demo`. The budgets are at 100% and the burn rates at 0.

## 1. Break it (2 min)

The app has a fault switch: `FAULT_ERROR_RATE` makes that share of `/orders` requests return `500`. In Git it's `config.faultErrorRate` in `environments/<env>/values.yaml`, and changing it through a commit is what the `gitops-revert` demo does. The copy is its own Application, so here you can set it as a Helm parameter on the Application instead:

```sh
./platform shell
kubectl -n argocd patch applications.argoproj.io orders-demo --type json \
  -p '[{"op":"add","path":"/spec/source/helm/parameters/-","value":{"name":"config.faultErrorRate","value":"0.2"}}]'
```

Argo CD syncs the change and the pods restart with 20% of orders failing. Don't `kubectl edit` the Deployment itself: Argo CD's self-heal would put it back within seconds.

Then send traffic, in the same shell:

```sh
k6 run --quiet --insecure-skip-tls-verify -e BASE_URL=https://orders-demo.localtest.me -e RATE=5 -e DURATION=30m app/k6/load.js
```

k6 complains that its `orders_slo_good` threshold is crossed. That's expected: you broke it.

## 2. Watch the budget burn (5 min)

On the dashboard (environment `orders-demo`):

- **POST /orders: share failing with 5xx** climbs to about 20%, far above the dashed 0.5% line.
- **Burn rate, availability (1 h)** jumps to about **40** (20% ÷ 0.5%).
- **Availability budget left (last 24 h)** drops below 0 within minutes, because the copy is new and has little good traffic in its window. On ogp it reached about −160% after 12 minutes of faults.
- **Firing SLO alerts** shows `OrdersGatewayAvailabilityFastBurn` **pending**, then **firing**. On ogp it went pending about 1 minute after the faults started and fired about 3 minutes after.

Why both windows? The 5-minute rate alone would page on every short blip. The 1-hour rate alone would keep paging long after a fix. Requiring both means the alert fires quickly for real problems and stops quickly once they're fixed.

Also look at **Prometheus → Alerts** (<https://prometheus.localtest.me/alerts>) and **Alertmanager** (<https://alertmanager.localtest.me>). That's the same alert, seen from the rule's side and from the side that routes notifications.

## 3. Follow the runbook (4 min)

The alert carries a `runbook_url`. Open [`runbooks/OrdersGatewayAvailabilityFastBurn.md`](../../runbooks/OrdersGatewayAvailabilityFastBurn.md) and use `orders-demo` for `<namespace>`:

1. **How bad, and where?** `sum by (code) (rate(http_requests_total{namespace="orders-demo", route="/orders", method="POST"}[5m]))` shows `500` next to `201`. Every pod and the single version fail alike, so it isn't one bad canary pod.
2. **What do the failing requests say?** In Explore, choose Loki: `{namespace="orders-demo", app="orders-gateway"} | json | level="ERROR"`. Each is a `500` with `duration_ms` near 0. The request failed instantly, without calling payments. (The response body says `{"error":"injected fault"}`; the log line doesn't.)
3. **Did something just change?** The app reads its settings from a ConfigMap (`envFrom`): `kubectl -n orders-demo get configmap orders-gateway -o yaml | grep FAULT` shows `FAULT_ERROR_RATE: "0.2"`, and Argo CD shows a recent sync of `orders-demo`.

So the runbook leads to the cause: an injected fault.

## 4. Fix it and watch it clear (5 min)

Remove the parameter (keep k6 running):

```sh
kubectl -n argocd get applications.argoproj.io orders-demo -o json |
  jq '{spec: {source: {helm: {parameters: [.spec.source.helm.parameters[] | select(.name != "config.faultErrorRate")]}}}}' |
  kubectl -n argocd patch applications.argoproj.io orders-demo --type merge --patch-file /dev/stdin
```

Now watch:

- The 5xx share and the **5 m** burn rate drop to 0 within a few minutes, as the 5-minute window forgets the failures.
- The **1 h** burn rate falls slowly. It still remembers the bad 10 minutes.
- The alert resolves once the 5-minute rate drops below 14.4, even though the 1-hour rate is still high. That's the short window doing its job. On ogp it cleared about 3½ minutes after the fix, while the 1 h burn rate was still about 32.
- The budget doesn't come back quickly: the failures stay in its 24-hour window. The panel is so far below 0 only because the copy is new, so those failures are measured against very little good traffic. Against a real 30-day budget, 20% failing for 10 minutes costs about 1% (0.2 × 10 min ÷ (0.005 × 43,200 min)). That's small, but the alert still paged, because at that pace the whole budget would be gone in about 2 days. The budget is what tells you whether you can afford more risk this month.

## 5. Clean up

Stop k6 (Ctrl-C), leave the shell, and delete the copy:

```sh
./platform demo clean
```

## Try next (optional)

`config.faultLatencyMs` adds delay to `/orders`. Set it to `400` and watch the **latency** SLO burn instead (`OrdersGatewayLatencyFastBurn`), while availability stays perfect.

## Check yourself

- Why does the fast-burn alert need both the 1 h and the 5 min window?
- 20% of requests fail for 10 minutes, then it's fixed. Roughly how much of a 30-day budget did that cost, and why did it still page?
- Why change `FAULT_ERROR_RATE` through the Argo CD Application (or Git) instead of `kubectl edit`?

Next: 5. Kubernetes operations _(coming)_.
