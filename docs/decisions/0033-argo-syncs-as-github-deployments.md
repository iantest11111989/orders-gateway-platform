# 0033: Argo CD's syncs shown on GitHub as Deployments

**Status:** Accepted, 2026-11-25

## Context

The pipeline's CI half shows on GitHub (CI · app, CD · app), but its CD half happens inside the cluster: Argo CD syncs dev after CD commits the image, and staging and prod after the promoter merges their PRs. GitHub never saw any of it, so the repo didn't read as a CI/CD pipeline (the owner's feedback).

## Choice

The patch promoter, already in the cluster with a GitHub token, reports each environment as a **GitHub Deployment** on every pass (GitHub mode only, where the promoter runs):

- It reads the `dev`, `staging` and `prod` Applications (sync status, health, synced revision) and the image tag from `environments/<env>/values.yaml` **at that revision**, from GitHub, so it needs no new cluster permissions.
- A **new Deployment** when the revision changes (`ref` = the synced commit, `environment` = dev, staging or prod; prod is marked a production environment), and a **new status** when the state changes: Synced and Healthy → `success`, OutOfSync or Progressing → `in_progress`, Degraded → `failure`. Nothing is written when nothing changed.
- `auto_inactive`, so each environment shows only its current deployment.
- Errors never block promotion: they're logged per environment, with a hint when the token lacks the permission.

The repo page's **Environments** panel then shows what each environment runs and since when, and commits and PRs show "deployed to staging".

## Consequences

- The promoter's fine-grained token needs **Deployments: Read and write** on this repo, in addition to its existing permissions. Without it the promoter logs the hint and carries on.
- Not in the default in-stack mode: there's no promoter and no GitHub. Watch Argo CD's UI (`:8081`) there.
- One write per environment per change, at most every 10 minutes (the CronJob's schedule); no write when nothing changed.
