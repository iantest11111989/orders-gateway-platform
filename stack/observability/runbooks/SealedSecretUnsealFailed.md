# SealedSecretUnsealFailed

Severity: ticket. Fix today.

The controller couldn't turn SealedSecret `<namespace>/<name>` (the alert's labels) into a Secret for 5 minutes. Whatever reads that Secret has the old value, or none.

## Check

```sh
./platform shell
kubectl -n <namespace> get sealedsecret <name> -o jsonpath='{.status.conditions}'; echo
kubectl -n kube-system logs deploy/sealed-secrets-controller --since=1h | grep -i <name>
kubectl -n <namespace> get secret <name> -o jsonpath='{.metadata.ownerReferences}'; echo
```

The condition message names the cause:

- `no key could decrypt secret`: sealed with another key, or for another name or namespace.
- `Resource "..." already exists and is not managed by SealedSecret`: a hand-made Secret is in the way.

## Fix

- Wrong key, name or namespace: reseal with the demo certificate and commit the output through a PR:
  `./platform shell scripts/seal.sh <namespace> <name> key=value...`
- A hand-made Secret in the way: delete it so the controller can create its own. Ask the owner first.

## Done when

`kubectl -n <namespace> get sealedsecret <name>` shows `SYNCED True` and the alert clears.
