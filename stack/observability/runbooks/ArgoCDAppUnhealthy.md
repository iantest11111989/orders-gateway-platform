# ArgoCDAppUnhealthy

Severity: ticket. Fix today.

An Application has been Degraded or Missing for 10 minutes. The `name` and `health_status` labels say which. Degraded: something it deployed is failing (pods crash, a Deployment can't get ready). Missing: a resource in Git doesn't exist in the cluster, usually because it was refused on apply.

## Check

1. Find the unhealthy resource (marked red in the Argo CD UI):
   ```sh
   ./platform shell
   argocd login --username admin --password admin12345
   argocd app get <name>
   ```
2. Look at its pods and events:
   ```sh
   kubectl -n <namespace> get pods
   kubectl -n <namespace> describe pod <pod>
   kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20
   ```
3. `./platform budget` lists OOM-killed containers.

## Fix

Fix the image, config or limits in Git. For `dev`, `staging` or `prod`, the SLO alerts page if users are affected.

## Done when

`argocd app get <name>` shows Healthy and the alert clears.
