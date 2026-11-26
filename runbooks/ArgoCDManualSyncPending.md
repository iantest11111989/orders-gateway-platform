# ArgoCDManualSyncPending

**Severity: ticket.** Nothing is broken; an environment is behind Git.

## What it means

The apps' staging and prod Applications sync by hand: `./pipeline cd <app> <env>` changes the env file and pushes it, then someone clicks **Sync** in Argo CD (or the command ran with `--sync`). This one has been OutOfSync for an hour, so the change was pushed but never synced. The environment still runs what it ran before. dev and the platform components sync on their own and raise `ArgoCDAppOutOfSync` instead.

## How to check

```sh
./platform shell
argocd app diff <name>          # what Git would change
git -C . log -3 -- cd/<app>/<env>.yaml   # the change waiting (in your checkout)
```

Or open `http://localhost:8081/applications/argocd/<name>`: it shows OutOfSync and the resources that would change.

## Fix

- **You meant to promote it:** click **Sync** on `<name>` at http://localhost:8081, or run `./pipeline cd <app> <env> --version <v> --sync`.
- **You didn't:** put the env file back (`./pipeline rollback <app> <env>`, or revert the commit) so Git matches what runs.

The alert clears once the Application is Synced.
