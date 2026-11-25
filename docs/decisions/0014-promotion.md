# 0014: CI promotes every signed image to dev; staging and prod move by PR

**Status:** Accepted, 2026-11-24

## Context

The brief (sections 7 and 10) says: on merge to main, CI bumps the image in `environments/dev/values.yaml` and Argo CD deploys it; promotion to staging and prod is a pull request the owner approves. Until now all three environments were moved by hand (decision 0009) and still ran `sha-85cbba12fef7`, an image from before signing (decision 0013), so Kyverno's signature check flags them.

## Choices

- **`promote-dev` job in `app.yml`**, after `publish` and `sign`. It sets dev to `sha-<12>@<digest-main>` with `scripts/set-image.sh`, commits as `github-actions[bot]` and pushes to `main`. Running after `sign` means dev never runs an unsigned digest.
- **A direct commit, not a PR.** The brief makes dev automatic, and the commit is the record: its message names the image, the digest and the workflow run that published and signed it.
- **`GITHUB_TOKEN` with `contents: write` on that job only.** `main` has no branch protection, so no other token is needed. A push made with `GITHUB_TOKEN` starts no workflows, so the bump can't loop. The `app` workflow's concurrency group already serializes runs on `main` and keeps only the newest pending one, so the newest commit's image wins. A push that races another commit is rebased and retried (three tries).
- **`scripts/set-image.sh <env> <tag> <digest>`** edits only `image.tag` and `image.digest` inside the `image:` block and keeps every comment. It refuses a malformed tag or digest, and a file where either key isn't found exactly once. The staging/prod promotion PRs and the automated patch path (brief section 10) will use it too.
- **Tag and digest together.** The pod runs `repository@digest` (decision 0009); the tag stays for people reading the file.

## Staging and prod (next PR)

They need a PR that `GITHUB_TOKEN` opens, which takes one repository setting the owner turns on: *Settings → Actions → General → Allow GitHub Actions to create and approve pull requests* (off today). PRs opened with `GITHUB_TOKEN` start no workflows, but `GITHUB_TOKEN` may send `workflow_dispatch`, so the promotion job will dispatch the checks on the PR's branch and their results show on the PR's head commit. No personal access token or GitHub App is needed.

## Consequences

- `main` gains a bot commit after every merge that publishes a new image. `git log -- environments/dev` is the dev deploy history.
- A merge that doesn't touch `app/**` (or the app workflow) publishes nothing, so dev doesn't move. That's intended: the image didn't change.
- If `sign` fails, `promote-dev` doesn't run and dev stays on the last signed image (re-run the jobs; decision 0013).

## Tests

- `scripts/set-image.sh`: rewrote dev's tag and digest with the comments intact; rejected a tag with a space, an unknown environment, and a file with two `tag:` keys (file left unchanged).
- shellcheck and actionlint (the pinned images CI uses): clean.
- The job itself can only run on `main`; its first run is this PR's merge commit, which publishes because the PR changes the app workflow.
