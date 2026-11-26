# SealedSecretsControllerDown

Severity: ticket. Fix today.

The Sealed Secrets controller in `kube-system` hasn't answered a metrics scrape for 10 minutes. Existing Secrets still work. New or changed SealedSecrets don't become Secrets until it is back.

## Check

```sh
./platform shell
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets
kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=50
kubectl -n kube-system get secrets -l sealedsecrets.bitnami.com/sealed-secrets-key
```

The last command lists its keys. It must have the demo key from `system/sealed-secrets/manifests/demo-key.yaml`. Without it, the controller makes a new key and can't decrypt anything in Git.

## Fix

- Crash or OOM: read the logs, and raise the limit in `system/sealed-secrets/values.yaml` in Git.
- Wrong key: check the `sealed-secrets` Application synced `demo-key.yaml`, then restart the controller:
  `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`
- Pod runs but the alert fires: the scrape is broken. Check recent NetworkPolicy changes in `system/network-policies/`.

## Done when

The alert clears and `kubectl get sealedsecrets -A` shows `SYNCED True` for each one.
