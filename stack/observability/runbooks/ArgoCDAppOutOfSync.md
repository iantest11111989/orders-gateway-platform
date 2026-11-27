# ArgoCDAppOutOfSync

Severity: ticket. Fix today.

An auto-sync Application (a platform component, or an app's dev) has differed from Git for 15 minutes. Self-heal normally fixes drift in seconds, so Argo CD is failing to apply what is in Git. The `name` label is the Application. Manual-sync apps (staging, prod) raise [ArgoCDManualSyncPending](ArgoCDManualSyncPending.md) instead.

## Check

1. Read the last sync result and the diff:
   ```sh
   ./platform shell
   argocd login --username admin --password admin12345
   argocd app get <name> --show-operation
   argocd app diff <name>
   ```
2. Match the message to a cause:
   - The API server refused a manifest: bad YAML, an unknown field, or a Kyverno Deny in `dev`, `staging`, `prod` or `demo` (a `:latest` or unsigned image).
   - The diff comes back after every sync: a controller or webhook keeps changing a field.
   - The repo or revision can't be read.

## Fix

- Refused manifest: fix or revert the commit in Git.
- A field that keeps changing: add it to `ignoreDifferences` in the Application's template in `stack/delivery/bootstrap/apps/templates/` (`<name>.yaml`, or `apps.yaml` for the apps).
- Then sync now with `argocd app sync <name>`, or wait about 3 minutes.

## Done when

`argocd app get <name>` shows Synced and the alert clears.
