# SealedSecretsControllerDown

**Severity: ticket.** Look at it today.

## What it means

The Sealed Secrets controller in `kube-system` hasn't answered a Prometheus scrape for 10 minutes. Existing Secrets keep working. New or changed **SealedSecrets** in Git won't be decrypted into Secrets until it's back, so changes to them don't take effect.

## Likely causes

- The pod is crash-looping, OOM-killed or unschedulable.
- It started without its key. The demo key (`gitops/manifests/sealed-secrets/demo-key.yaml`) must exist before the controller starts. If it doesn't, the controller generates a new key and can't decrypt anything in Git.
- Only the scrape is broken (a NetworkPolicy change).

## How to check

```sh
./platform shell
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets
kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=50
kubectl -n kube-system get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key   # the key(s) it has
```

## How to fix

- Crash or OOM: check the logs, and raise the limit in the sealed-secrets values through a PR.
- Wrong key: make sure the `sealed-secrets` Application synced `demo-key.yaml`, then restart the controller: `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`.

## Verify recovery

The alert clears, and every SealedSecret is synced:

```sh
kubectl get sealedsecrets -A
```

Each one shows `SYNCED True`.
