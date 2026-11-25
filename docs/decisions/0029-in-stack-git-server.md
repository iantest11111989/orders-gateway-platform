# 0029: Argo CD syncs from an in-stack Git server holding this checkout

**Status:** Accepted, 2026-11-25

## Context

Argo CD synced from this repo on GitHub. Someone who runs the platform from a clone, a fork or a tarball on a fresh VM would then deploy *our* GitHub state, not the files in front of them: their edits would never reach the cluster, and a private or renamed repo would install nothing. Shipping a new version or rolling back "by Git change" needs a remote they can push to. The assignment suggests an in-stack Git server for its optional GitOps item.

## Choices

- **soft-serve inside the cluster** (`gitops/manifests/git-server/`, Kustomize, applied by `scripts/git-sync.sh` from `up.sh`, before Argo CD exists): one 23 MB Go binary, pinned by digest, with anonymous **read-only** HTTP clones (what Argo CD uses) and pushes only with the bootstrap's SSH key. In the cluster, not in Compose, so Argo CD reaches it by Service name and it lives and dies with the cluster. Its repositories sit on a PVC: `docker compose stop`/`start` keeps them. It runs as uid 1000 with a read-only root filesystem under Pod Security `restricted`, and a NetworkPolicy lets only `argocd` read. Gitea would add a UI and Actions for about 300 MB more; it's the upgrade path, not needed here.
- **A snapshot of the working tree, not the checkout's Git history.** `git-sync.sh` commits the files as they are, committed or not and minus `.gitignore`, through a throwaway Git directory. It works for a tarball with no `.git`. Each snapshot's parent is the previous in-stack `main`, so Argo CD shows a revision trail and `git revert` works there. Nothing is pushed if nothing changed. Every `up` (and Compose start) syncs again, then asks Argo CD to refresh.
- **The admin key lives in the cluster** (Secret `git/git-admin`), next to the data it guards: soft-serve takes its admin key only when it first creates its database, so a key kept anywhere else could drift from the data and lock pushes out.
- **Two modes.** Without `REPO_URL` (Compose, `./platform up`, CI): in-stack, this checkout. With `REPO_URL=https://github.com/...` (the owner's long-running cluster): GitHub mode, where CI's promotion PRs and the patch promoter (decision 0024) apply. The promoter's CronJob is only rendered in GitHub mode; its order trickle runs in both, so the dashboards have traffic.

## Consequences

- CI's cluster job no longer sets `REPO_URL`: it tests exactly what a reviewer runs.
- The `gitops-revert` demo pushes to the repo Argo CD syncs from; in in-stack mode that's the in-stack server (updated with the ship/rollback work).
- In-stack history isn't the checkout's history: a snapshot says which local HEAD (and whether there were uncommitted changes) it came from.
