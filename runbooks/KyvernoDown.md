# KyvernoDown

**Severity: page.** A security control is off right now.

## What it means

No Kyverno admission controller has answered a Prometheus scrape for 5 minutes. Kyverno's webhooks use `failurePolicy: Ignore`, so the API server admits pods **without** Kyverno's checks while it's down. `:latest` and unsigned images can get into the app namespaces (`dev`, `staging`, `prod`, `demo`). Pod Security `restricted` still applies, because it's built into the API server.

## Likely causes

- The pod is crash-looping or OOM-killed (check its memory limit in `system/kyverno/values.yaml`).
- It can't be scheduled: the nodes are full (`./platform budget`).
- Only the metrics scrape is broken, for example a NetworkPolicy change in `system/network-policies/kyverno.yaml`. Then Kyverno is still working.

## How to check

```sh
./platform shell
kubectl -n kyverno get pods
kubectl -n kyverno describe deploy kyverno-admission-controller | tail -20
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50
# Is it enforcing? This dry run must be refused:
kubectl -n dev run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name \
  --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"try-latest","image":"docker.io/library/busybox:latest","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}'
```

In Grafana, the **Kyverno** dashboard's admission panels go flat while it's down.

## How to fix

- OOM-killed: raise the limit in `system/kyverno/values.yaml` through a PR. Don't `kubectl edit`, because Argo CD reverts it.
- Not scheduled: free up room, for example `./platform demo clean`, or find what grew with `./platform budget`.
- In Argo CD, check the `kyverno` Application is Synced and Healthy, and sync it if needed.

## Afterwards

Pods admitted while Kyverno was down weren't checked. List the app pods (`dev`, `staging`, `prod`) created in that window and check their images are tagged and signed:

```sh
kubectl get pods -A -l team=orders -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,IMAGE:.spec.containers[*].image'
```

## Verify recovery

The alert clears, the dry run above is refused with `Images must not use the latest tag`, and `./platform verify` passes.
