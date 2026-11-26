# KyvernoDown

Severity: page. A security control is off.

No Kyverno admission controller has answered a metrics scrape for 5 minutes. Its webhooks fail open (`failurePolicy: Ignore`), so new pods skip the tag and signature policies. Pod Security `restricted` still applies.

## Check

1. Look at the pod:
   ```sh
   ./platform shell
   kubectl -n kyverno get pods
   kubectl -n kyverno describe deploy kyverno-admission-controller | tail -20
   kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=50
   ```
2. Check it enforces. This dry run must be refused with `Images must not use the latest tag`:
   ```sh
   kubectl -n dev run try-latest --image=docker.io/library/busybox:latest --restart=Never --dry-run=server -o name \
     --overrides='{"apiVersion":"v1","spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"try-latest","image":"docker.io/library/busybox:latest","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}'
   ```
   If it is refused, Kyverno works and only the scrape is broken. Check `system/network-policies/kyverno.yaml`.

## Fix

- OOM-killed: raise the limit in `system/kyverno/values.yaml` in Git.
- Not scheduled (nodes full): `./platform budget`, then free room, for example `./platform demo clean`.
- In Argo CD, check the `kyverno` Application is Synced and Healthy.

## Afterwards

Pods admitted during the outage were not checked. List recent pods in the app namespaces and check their images are tagged and signed:

```sh
kubectl get pods -A --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,CREATED:.metadata.creationTimestamp,IMAGE:.spec.containers[*].image' \
  | grep -E '^(dev|staging|prod|demo) '
```

## Done when

The dry run above is refused, the alert clears, and `./platform verify` passes.
