# RolloutAborted

**Severity: ticket.** Users are already back on the stable version; find out why the new one failed before trying again.

## What it means

A canary (Argo Rollouts) outside the `demo` copy aborted. prod runs a plain Deployment, so no environment uses a Rollout today; the alert stays for any that does. At each step an AnalysisRun checks the canary's pods against the SLO: 5xx ratio at most 0.5% and p99 latency at most 300 ms, measured 4 times, 30 seconds apart. A **second** failed measurement (`failureLimit: 1`) aborts the canary and sends all traffic back to the stable version. Someone can also abort it by hand.

The new version stays out until a fixed image is promoted. `demo` is excluded: the `canary-fail` demo aborts on purpose.

## How to check

```sh
./platform shell
kubectl argo rollouts -n <namespace> get rollout app        # the step it stopped at, and the message
kubectl -n <namespace> get analysisruns --sort-by=.metadata.creationTimestamp
kubectl -n <namespace> describe analysisrun <the newest one>          # which metric failed, with its values
```

The **Argo Rollouts** dashboard in Grafana shows the same: **Recent analysis runs** and **Analysis metrics** (which of `error-ratio` or `p99-latency` failed). In Loki, `{namespace="<namespace>"} | json | level="ERROR"` shows the canary's failing requests, with their `version`.

## Fix

1. Compare the failed version with stable: the errors or latency the analysis saw, and what changed in the image (its commit range is in the promotion PR's `Promotion-Range`).
2. Fix it in the app and let a new image go through dev and staging again. Don't retry the same image.
3. If the analysis itself was wrong (no traffic, a query bug), fix the AnalysisTemplate in `charts/orders-gateway/templates/analysistemplate.yaml`, then retry with `kubectl argo rollouts -n <namespace> retry rollout app`.
