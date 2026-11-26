# 4. SLOs: break the app, watch the error budget burn

Time: about 20 minutes, mostly waiting. You need a running stack and exercises [1](01-prometheus.md) to [3](03-loki.md).

You'll make the app fail, watch the burn-rate alert fire, follow the runbook to the cause, fix it, and watch the alert clear.

## The SLO

- Availability: 99.5% of `/work` and `/echo` requests don't return a 5xx.
- Latency: 99.5% of `/echo` and `/version` requests finish within 250 ms.

The 0.5% allowed to fail is the error budget. The burn rate is how fast you spend it: 1 uses up the budget in exactly 30 days, 14.4 in about 2 days.

`OrdersGatewayAvailabilityFastBurn` fires when the burn rate is over 14.4 (7.2% failing) over both the last 1 hour and the last 5 minutes, for 2 minutes. The rules are in [`alerts/orders-gateway-slo.yaml`](../../alerts/orders-gateway-slo.yaml).

## 0. Make a copy to break

Never break the real environments. Make a copy of dev in namespace `demo`:

```sh
./platform demo rolling-update --keep
```

After about 2 minutes, Argo CD Application `orders-gateway-demo` runs at <http://localhost:8084>. Open Grafana's orders-gateway dashboard and set environment to `demo`.

## 1. Break it

1. Set the fault rate on the copy. 20% of `/work` and `/echo` requests will return 500:

   ```sh
   ./platform shell
   kubectl -n argocd patch applications.argoproj.io orders-gateway-demo --type json \
     -p '[{"op":"add","path":"/spec/source/helm/parameters/-","value":{"name":"config.faultErrorRate","value":"0.2"}}]'
   ```

   Argo CD syncs it and the pods restart. In the real environments you'd change `config.faultErrorRate` in `cd/orders-gateway/<env>.yaml` instead. Don't `kubectl edit` the Deployment: Argo CD would undo it.

2. Send traffic from the same shell:

   ```sh
   k6 run --quiet -e BASE_URL=http://localhost:8084 -e RATE=5 -e DURATION=30m apps/orders-gateway/k6/load.js
   ```

   k6 warns that `orders_slo_good` is crossed. That's expected.

## 2. Watch the budget burn

On the dashboard:

- /work and /echo: share failing with 5xx climbs to about 20%.
- Burn rate, availability (1 h) climbs toward 40 (20% ÷ 0.5%).
- Availability budget left (last 24 h) drops below 0 within minutes. The copy is new, so there's little good traffic to set against the failures.
- Firing SLO alerts shows the alert pending after about a minute, then firing a few minutes later.

The alert uses two windows for a reason. The 5-minute window alone would page on short blips. The 1-hour window alone would keep paging long after a fix. Together, the alert fires fast and clears fast.

You can see the same alert in Prometheus (<http://localhost:9090/alerts>) and Alertmanager (<http://localhost:9093>).

## 3. Follow the runbook

Open [`runbooks/OrdersGatewayAvailabilityFastBurn.md`](../../runbooks/OrdersGatewayAvailabilityFastBurn.md) and use `demo` as the namespace.

1. Where is it failing? In Prometheus:

   ```promql
   sum by (pod) (rate(http_requests_total{namespace="demo", service="orders-gateway", status=~"5.."}[5m]))
   ```

   Every pod fails alike, so it isn't one bad pod.

2. What do the logs say? In Loki: `{namespace="demo", app="orders-gateway"} | json | level="error"`. Each is a 500 with `duration_ms` near 0: the request failed before doing any work.

3. What changed?

   ```sh
   kubectl -n demo get configmap orders-gateway -o yaml | grep FAULT
   ```

   It shows `FAULT_ERROR_RATE: "0.2"`. That's the cause.

## 4. Fix it and watch it clear

1. Remove the parameter. Keep k6 running:

   ```sh
   kubectl -n argocd get applications.argoproj.io orders-gateway-demo -o json |
     jq '{spec: {source: {helm: {parameters: [.spec.source.helm.parameters[] | select(.name != "config.faultErrorRate")]}}}}' |
     kubectl -n argocd patch applications.argoproj.io orders-gateway-demo --type merge --patch-file /dev/stdin
   ```

2. Watch:
   - The 5xx share drops to 0 within a few minutes.
   - The 1 h burn rate falls slowly; it still remembers the failures.
   - The alert clears once the 5-minute rate drops, even while the 1-hour rate is high.
   - The budget doesn't come back: the failures stay in its 24-hour window.

Against a real 30-day budget, 20% failing for 10 minutes costs about 1%. It still paged, because at that pace the whole budget would be gone in 2 days.

## 5. Clean up

Stop k6 with Ctrl-C, leave the shell, and run:

```sh
./platform demo clean
```

## Try next

- Burn the latency SLO: run k6 with `-e WORK_MS=1500 -e RATE=10`. Each `/work` blocks the pod's single event loop, so `/echo` waits behind it, and `OrdersGatewayLatencyFastBurn` fires while availability stays fine.
- Set `config.faultLatencyMs` to `400`. Only `/work` slows down, which the latency SLO leaves out, so nothing fires.

## Check yourself

- Why does the fast-burn alert need both windows?
- 20% fail for 10 minutes. Roughly how much of a 30-day budget is that, and why did it page?
- Why change the fault rate through Argo CD or Git and not `kubectl edit`?
- Why isn't a 2-second `/work` call a latency SLO violation?

Next: [5. Kubernetes operations](05-k8s-operations.md).
