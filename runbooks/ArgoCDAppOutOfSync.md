# ArgoCDAppOutOfSync

**Severity: ticket.** Look at it today: changes merged for this application aren't reaching the cluster.

## What it means

The live state of an Argo CD Application has differed from Git for 15 minutes. Every Application here has self-heal on, so a manual change is put back within seconds ([decision 0005](../docs/decisions/0005-gitops-layout.md)). An app that *stays* OutOfSync means Argo CD keeps trying and failing to apply what's in Git. The `name` label says which one.

## Likely causes

- **A manifest the API server rejects:** invalid YAML after a merge, a field the CRD doesn't know, or a Kyverno Deny in an app namespace (`dev`, `staging`, `prod`, `demo`) (a `:latest` or unsigned image, [decision 0022](../docs/decisions/0022-enforce-in-orders.md)).
- **A field something else keeps changing** (a controller or a mutating webhook) that isn't in the app's `ignoreDifferences`, so every sync is immediately out of date again.
- **The repo can't be read:** GitHub is down, or the revision the app points at doesn't exist.

## How to check

```sh
./platform shell
argocd app get <name> --show-operation      # the last sync's result and message
argocd app diff <name>                      # what differs from Git
kubectl -n argocd get applications.argoproj.io <name> -o jsonpath='{.status.conditions}'
```

Or open `http://localhost:8081/applications/argocd/<name>`: the sync status and the resources marked OutOfSync. The **Argo CD** dashboard in Grafana shows when it started.

## Fix

Fix it in Git, not in the cluster: revert or correct the commit that broke the sync. If a controller keeps changing a field, add that field to the app's `ignoreDifferences` (in `gitops/apps/templates/<name>.yaml`). Argo CD syncs again within about 3 minutes, or right away with `argocd app sync <name>`.
