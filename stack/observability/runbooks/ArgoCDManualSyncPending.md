# ArgoCDManualSyncPending

Severity: ticket. Nothing is broken.

A manual-sync Application (an app's staging or prod, named `<app>-<env>`) has been OutOfSync for an hour. Someone ran `./pipeline cd` but nobody clicked Sync, so the environment still runs the old version.

## Check

1. See what is waiting:
   ```sh
   ./platform shell
   argocd login --username admin --password admin12345
   argocd app diff <name>
   ```
2. On the host, see the change: `git log -3 -- apps/<app>/cd/<env>.yaml`.

## Fix

- To promote it: click Sync on `<name>` at http://localhost:8081, or run `./pipeline cd <app> <env> --version <v> --sync`.
- To drop it: `./pipeline rollback <app> <env>`, so Git matches what runs.

## Done when

The Application shows Synced and the alert clears.
