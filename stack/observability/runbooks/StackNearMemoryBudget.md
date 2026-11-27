# StackNearMemoryBudget

Severity: ticket. Fix today, before the next spike OOM-kills something.

Memory across the three kind nodes has been above 90% of the 12 GiB budget for 10 minutes. Each node is capped at 4 GiB. A full node OOM-kills pods, and in the worst case kubelet or containerd.

## Check

1. Find what grew:
   ```sh
   ./platform budget --watch 60
   ./platform kubectl top pods -A --sort-by=memory | head -15
   ```
2. The Grafana Budget dashboard shows memory by namespace over time.

## Fix

- A demo or load test left running: `./platform demo clean`, or stop the k6 process.
- A component that keeps growing: check its limits in its `values.yaml` under `stack/` (Prometheus: `stack/observability/prometheus/values.yaml`). Prometheus with a high-cardinality label is the usual one (`docs/learn/01-prometheus.md`, section 4).
- Docker has less than 12 GiB: run `./platform doctor`. Under Colima: `colima start --cpu 6 --memory 12`.

Change limits in Git, not with `kubectl edit`.

## Done when

`./platform budget` shows memory back under 90% and the alert clears.
