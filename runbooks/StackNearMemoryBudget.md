# StackNearMemoryBudget

**Severity: ticket.** The stack is close to its 12 GiB budget; the next spike will OOM-kill something.

## What it means

Memory across the three kind nodes (pods plus kubelet and containerd, from cAdvisor's root cgroup on each node) has been above **90% of 12 GiB** for 10 minutes. Each node container is capped at 4 GiB by `./platform up`. A node at its cap OOM-kills pods, and in the worst case kubelet or containerd. Normally the stack uses about 60% (see the README's resource budget).

## How to check

```sh
./platform budget --watch 60        # measured use per node and per namespace, and any OOM kills
./platform kubectl top pods -A --sort-by=memory | head -15
```

The **Budget** dashboard in Grafana shows the same per namespace over time, so you can see what grew.

## Likely causes and fixes

- **A demo or load test left running:** `./platform demo clean`, or stop the k6 process.
- **A component growing without limit** (a leak, or a cache: Prometheus series, Loki chunks). Find it in the per-namespace view and check its limits in `system/<component>/values.yaml`. Prometheus with many new series is the usual suspect: look for a label with unbounded values (exercise 1 in `docs/learn/`).
- **Docker has less than 12 GiB:** `./platform doctor`. Under Colima: `colima start --cpu 6 --memory 12`.

Change limits in Git, not with `kubectl edit`: Argo CD would put them back.
