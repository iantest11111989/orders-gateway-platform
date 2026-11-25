# SealedSecretUnsealFailed

**Severity: ticket.** Look at it today.

## What it means

The controller couldn't turn one SealedSecret (the alert's `namespace` and `name`) into a Secret: its `Synced` condition has been `False` for 5 minutes. Whatever reads that Secret still has the old value, or none.

## Likely causes

- **Sealed with a different key**, for example with `kubeseal` against another cluster, or before the demo key was set up. The controller can only decrypt what was sealed with its own key.
- **Sealed for a different name or namespace.** The default `strict` scope ties the ciphertext to both.
- **A Secret with that name already exists and isn't owned by the SealedSecret** (created by hand).

## How to check

```sh
./platform shell
kubectl -n <namespace> get sealedsecret <name> -o jsonpath='{.status.conditions}' ; echo
kubectl -n kube-system logs deploy/sealed-secrets-controller --since=1h | grep -i <name>
kubectl -n <namespace> get secret <name> -o jsonpath='{.metadata.ownerReferences}' ; echo
```

The condition's message names the cause, for example `no key could decrypt secret` or `Resource "..." already exists and is not managed by SealedSecret`.

## How to fix

- Wrong key, name or namespace: reseal against this cluster's key. Run `kubeseal --fetch-cert` in the toolbox, seal with `--namespace <namespace> --name <name>`, and commit the new file through a PR.
- An unmanaged Secret is in the way: delete it so the controller can create its own. Ask the owner first, since it's a deletion.

## Verify recovery

`kubectl -n <namespace> get sealedsecret <name>` shows `SYNCED True` and the alert clears.
