# KyvernoPolicyErrors

Severity: ticket. Fix today.

A Kyverno policy (the `policy_name` label) returned an error instead of pass or fail in the last 15 minutes. With `failurePolicy: Ignore` the request is usually admitted, so the check didn't happen.

## Check

1. Find the policy and what it was checking:
   ```promql
   sum by (policy_name, resource_kind, resource_namespace) (
     increase({__name__=~"kyverno_(image_)?validating_policy_results_total", result="error"}[1h]))
   ```
2. Read the errors and recent policy changes:
   ```sh
   ./platform shell
   kubectl -n kyverno logs deploy/kyverno-admission-controller --since=30m | grep -i error | tail -20
   kubectl get events -A --field-selector reason=PolicyError --sort-by=.lastTimestamp | tail
   git log --oneline -5 -- policies/
   ```
3. The Grafana Kyverno dashboard's Policy errors panel shows when it started.

## Fix

- `verify-image-signatures` can't reach GHCR or Sigstore: usually transient, so watch it. If it persists, check egress from the `kyverno` namespace.
- A CEL expression breaks on an object: fix the policy in `policies/`, add a test in `policies/tests/`, and open a PR. If urgent, revert the policy change.

## Done when

The query above stops rising and the alert clears.
