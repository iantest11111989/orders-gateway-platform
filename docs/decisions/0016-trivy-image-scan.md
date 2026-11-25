# 0016: Trivy scans the app image in CI

**Status:** Accepted, 2026-11-24

## Context

The brief (section 9.3) asks for Trivy image scanning in CI. Decision 0002 also names the Trivy Operator for scanning in the cluster. The app image is the only image this repo builds (decision 0013). Its SBOM lists what's inside it; Trivy checks that against the public vulnerability databases.

## Choices

- **Gate on fixable HIGH and CRITICAL only** (`--severity HIGH,CRITICAL --ignore-unfixed`; findings exit 3 and scanner errors exit with another non-zero code, see decision 0019). A finding with no fix can't be acted on, and failing on it would only teach people to ignore the check. Lower severities show up in Renovate's normal update flow.
- **Scan in two places with one script.** `scripts/scan-image.sh` runs:
  - in the pull request `image` job, against the image the PR just pushed to its localhost registry;
  - in a `scan` job on main, against the published `main` digest.

  `promote-dev` needs `scan`, so dev never gets an image with a fixable HIGH or CRITICAL finding. The demo tags (`v1`, `v2`, `v2-bad`) are built from the same code and dependencies, so the main image stands in for them.
- **Trivy runs from its image, pinned by tag and digest** (`TRIVY_IMAGE` in `app.yml`). A Renovate regex manager keeps it current. No third-party action runs with this repo's token.
- **DB fallback.** The vulnerability DB comes from `ghcr.io/aquasecurity/trivy-db`, with `public.ecr.aws/aquasecurity/trivy-db` as fallback, so GHCR rate limits don't fail a run.

## Consequences

- A new CVE in a dependency fails the next PR that touches the app, even if the PR didn't cause it. The fix is a dependency bump, usually already opened by Renovate.
- Images already running aren't rescanned yet. The Trivy Operator (decision 0002), or a scheduled scan of the digests the environments run, comes later; this ADR covers only the CI gate.
- **If main's scan fails,** the images stay published and signed, but dev doesn't move, and neither do the staging/prod promotion PRs, which wait on `promote-dev`. Fix it with a dependency bump in a PR, whose own scan has to pass; its merge publishes, scans and promotes as usual. Re-running the failed `scan` job only helps if the finding was a DB glitch.
- Both platforms (linux/amd64 and linux/arm64) are scanned. Given an index, Trivy would scan only the runner's platform.
- No exceptions file yet. If one is needed, a `.trivyignore` with an expiry date and a reason per entry is the plan.

## Tests

- `scripts/scan-image.sh` on dev's current image (`sha256:168023a1…`): 0 findings for both Debian (distroless) and the Go binary, exit 0.
- On `golang:1.20-alpine` (old Go toolchain): findings, exit 1.
- shellcheck, actionlint and `renovate-config-validator --strict` are clean. A local Renovate dry run detects the Trivy pin (0.76.2 plus digest).
