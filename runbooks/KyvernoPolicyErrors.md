# KyvernoPolicyErrors

**Severity: ticket.** Look at it today.

## What it means

A Kyverno policy returned **error** instead of pass or fail for some admission requests in the last 15 minutes. An erroring policy doesn't judge the pod on its merits. With `failurePolicy: Ignore` the request is usually admitted, so the check it was meant to make didn't happen.

## Likely causes

- **`verify-image-signatures` can't reach the registry or Sigstore** (GHCR, Rekor, Fulcio's roots) to verify a signature: network trouble, or a rate limit.
- **A CEL expression breaks on an object it didn't expect**, for example a field that's absent, after a policy change or a Kubernetes upgrade.
- **A policy change** in `policies/` that passed `kyverno test` but meets a real object the tests don't cover.

## How to check

```promql
# Which policies, and on what?
sum by (policy_name, resource_kind, resource_namespace) (
  increase({__name__=~"kyverno_(image_)?validating_policy_results_total", result="error"}[1h]))
```

```sh
./platform shell
kubectl -n kyverno logs deploy/kyverno-admission-controller --since=30m | grep -i error | tail -20
kubectl get events -A --field-selector reason=PolicyError --sort-by=.lastTimestamp | tail
git log --oneline -5 -- policies/    # did a policy change recently?
```

The **Kyverno** dashboard's **Policy errors** panel shows when it started.

## How to fix

- Registry or Sigstore unreachable: it's usually transient, so wait and watch. If it keeps happening, check egress from the `kyverno` namespace.
- A broken expression: fix the policy in `policies/`, add a test in `policies/tests/` for the object that broke it, and open a PR. If it's urgent, revert the policy change with a PR.

## Verify recovery

The query above stops increasing and the alert clears after its 15-minute window. `./platform verify` passes.
