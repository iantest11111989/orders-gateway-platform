# 0030: Ship and roll back by Git change, with a local image

**Status:** Accepted, 2026-11-25

## Context

The assignment wants one documented, repeatable way to ship a new version of the app (build the image, make it available to the cluster, roll it out) and one to roll it back, followed by a reviewer while traffic flows. Argo CD owns the cluster's state (self-heal), and since decision 0029 it syncs from an in-stack Git server holding the checkout.

## Choices

- **`./platform ship [--env ENV] [TAG]`** builds `app/` as `localhost/orders-gateway:TAG` (default `local-<UTC timestamp>`, never `latest`), loads it into every kind node with `kind load` (no registry, no credentials), writes the image into `environments/ENV/values.yaml` (repository, tag, empty digest), and pushes the checkout to the in-stack Git server. Argo CD applies it and the Deployment rolls (maxSurge 1, maxUnavailable 0, readiness-gated, preStop drain). It waits for the rollout, then prints the pods by version and the 5-minute availability SLO from Prometheus.
- **`./platform rollback [--env ENV]`** reads the in-stack Git history of that values file, puts back the image from before its last image change, and ships that the same way. A rollback is a new commit, not a history rewrite.
- **Not `kubectl rollout undo` or `kubectl set image`:** self-heal would put Git's version back within seconds. The change you ship is a visible edit to a values file in your checkout, which you can commit, diff or revert.
- **Local images and policy:** `localhost/orders-gateway:` is on the registry allow-list (#82). The signature policy only covers CI's `ghcr.io` images, so local builds are admitted deliberately; production would admit only signed CI images, which is the GitHub-mode path (CI publishes and signs; promotion PRs; decisions 0013–0015, 0024).
- **Default `ENV` is prod**, the environment the contract serves at `:8080`.

## Consequences

- CI's cluster job ships a baseline, then a new version, then rolls back, all with a request loop running against `:8080`. Any non-200 fails it.
- Ship and rollback refuse to run in GitHub mode (`REPO_URL` set), where the in-stack server isn't what Argo CD follows. Commit and push to GitHub there.
