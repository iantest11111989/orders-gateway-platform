# TrivyOperatorDown

**Severity: ticket.** Look at it today.

## What it means

Trivy Operator hasn't answered a Prometheus scrape for 15 minutes. While it's down, images that start running aren't scanned, and existing reports aren't refreshed. Until it's back, scan the image by hand: `scripts/scan-image.sh` (or `./pipeline ci`, which scans every build).

## Likely causes

- The operator or its built-in Trivy server is OOM-killed. Loading the vulnerability DB is its biggest memory use.
- It can't download the vulnerability DB (registry rate limits) and is restarting.
- Only the scrape is broken.

## How to check

```sh
./platform shell
kubectl -n trivy-system get pods
kubectl -n trivy-system logs deploy/trivy-operator --tail=50
kubectl -n trivy-system get events --sort-by=.lastTimestamp | tail
```

`./platform budget` shows whether it was OOM-killed.

## How to fix

- OOM: raise its limit in `system/trivy-operator/values.yaml` through a PR, and keep the 6 CPU / 12 GiB budget in mind (`./platform budget`).
- DB download failing: usually transient, so wait. The operator retries.

## Verify recovery

The alert clears, and new VulnerabilityReports appear:

```sh
kubectl get vulnerabilityreports -A --sort-by=.metadata.creationTimestamp | tail -3
```
