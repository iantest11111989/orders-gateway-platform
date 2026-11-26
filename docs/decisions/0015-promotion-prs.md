# 0015: CI opens the staging and prod promotion PRs

**Status:** Accepted, 2026-11-24

## Context

The brief (sections 7 and 10) has CI open promotion PRs for staging and prod that the owner approves. Dev already follows every signed image (decision 0014). Staging and prod still run an image from before signing, so Kyverno's signature check flags them.

## Choices

- **Job `promote-prs` in `app.yml`**, after `promote-dev`, one matrix leg per environment. It rebuilds branch `promote/<env>` from `main` with only that environment's `image.tag`/`image.digest` changed (`scripts/set-image.sh`), then opens a PR from it, or updates the open one.
- **One branch per environment, force-pushed by CI.** Each run rebuilds the branch from the newest `main`, so the PR always shows one change against the newest signed image and never goes stale or conflicts. Like Renovate's branches, these belong to the automation: people review and merge them but don't push to them. Before the push the job checks that the branch's last commit is `github-actions[bot]`'s, and fails otherwise, so a commit someone made by hand is never overwritten. No other branch is force-pushed.
- **`GITHUB_TOKEN`, no PAT or GitHub App.** The job gets `contents`, `pull-requests` and `actions` write. Opening a PR with it needs the repository setting *Allow GitHub Actions to create and approve pull requests*, which the owner turns on once. Until then the job pushes the branch, logs a warning that says what to turn on, and doesn't fail `main`. Only that error ("not permitted to create or approve pull requests") is downgraded; any other failure of `gh pr create` fails the job.
- **Checks through `workflow_dispatch`.** A PR opened with `GITHUB_TOKEN` starts no `pull_request` workflows, but `GITHUB_TOKEN` may dispatch one. The job runs `platform.yml` on the branch, and its results attach to the branch's head commit, so they show on the PR.
- **The owner merges.** Nothing here approves or merges. A prod merge starts the Argo Rollouts canary (decision 0011), which pauses at 10% without traffic.

## Consequences

- At most two promotion PRs are open at a time, each pointing at the newest image dev runs.
- Staging and prod can skip images. That's intended: they move only when the owner merges.
- The automated patch path (brief section 10, a separate PR) can merge these same PRs once its soak gates pass.

## Tests

- actionlint 1.7.12 (the pinned CI image): clean.
- `scripts/set-image.sh` is covered in decision 0014.
- The job runs only on `main`. Its first run is this PR's merge commit, which publishes because the PR changes `app.yml`.

_Since 2026-11-25 the app workflow is split into `ci-app.yml` (pull requests) and `cd-app.yml` (main); what this record says of `app.yml` now applies to `cd-app.yml` (decision 0013's addendum)._
