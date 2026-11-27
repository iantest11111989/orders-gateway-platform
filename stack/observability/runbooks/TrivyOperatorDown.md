# TrivyOperatorDown

Severity: ticket. Fix today.

Trivy Operator hasn't answered a metrics scrape for 15 minutes. New images aren't scanned and existing reports aren't refreshed. Until it is back, scan by hand with `scripts/scan-image.sh <image>` (set `TRIVY_IMAGE` as its header shows). `./pipeline ci` also scans every build.

## Check

```sh
./platform shell
kubectl -n trivy-system get pods
kubectl -n trivy-system logs deploy/trivy-operator --tail=50
kubectl -n trivy-system get events --sort-by=.lastTimestamp | tail
```

`./platform budget` shows whether it was OOM-killed.

## Fix

- OOM-killed (loading the vulnerability DB uses the most memory): raise the limit in `stack/trivy-operator/values.yaml` in Git. Stay within the 6 CPU / 12 GiB budget.
- The DB download fails (registry rate limit): usually transient. The operator retries.
- Pod runs but the alert fires: the scrape is broken. Check `stack/network-policies/trivy-system.yaml`.

## Done when

The alert clears and new reports appear:
`kubectl get vulnerabilityreports -A --sort-by=.metadata.creationTimestamp | tail -3`
