# 0019: Daily rescan of the images the environments run

**Status:** Accepted, 2026-11-25

## Context

Decision 0016 gates each image on a Trivy scan when it's built. A CVE published after that doesn't show up anywhere until the next app change. Decision 0002 named the Trivy Operator for scanning in the cluster. Its consequences note left rescanning of running images open.

## Choices

- **A scheduled workflow, `rescan.yml`, not the Trivy Operator.** Every day (09:17 UTC), and by hand from the Actions tab, it reads `image.digest` from `environments/{dev,staging,prod}/values.yaml` and scans each digest with `scripts/scan-image.sh`, the same script and gate as decision 0016 (fixable HIGH/CRITICAL, both platforms). This repo builds only the app image, and the environments pin it by digest, so Git already says exactly what runs. The Operator would add a controller and per-image scan Jobs to a 6 CPU / 12 GiB cluster (decision 0002) to learn the same thing, and only while the cluster is up.
- **Deduplicated:** staging and prod often run the same digest, which is then scanned once.
- **One tracking issue** ("Vulnerabilities in running images", label `security`). A run with findings opens it, or comments on it if it's already open. The next clean run closes it. The run itself also fails, so the Actions tab shows it too.
- **Findings and outages are kept apart.** `scan-image.sh` exits 3 for findings and with another non-zero code for scanner errors, such as a registry 429 or a DB download failure. A run with only errors fails, so it's visible in the Actions tab, but it leaves the issue alone. It neither reports findings nor closes an open issue on a scan that didn't happen.
- **Same Trivy pin as `app.yml`.** The Renovate regex manager now covers both files.

## Consequences

- Third-party images (Argo CD, Prometheus and so on) aren't scanned. Their charts are kept current by Renovate. Scanning them would turn up findings this repo can't fix, except by waiting for the upstream release Renovate already brings in.
- The fix for a finding is a dependency bump in the app. Its merge publishes, scans and promotes a new image to dev (decisions 0014 to 0016). Staging and prod then move through their promotion PRs.

## Tests

- I ran the scan step locally (bash 5, Docker) against the three digests in Git today: dev (`ee319c18…`) and staging/prod (`09c2177c…`, scanned once) are all clean, and the output is `status=0`.
- `scan-image.sh` exit codes: 0 for dev's image, 3 for `golang:1.20-alpine`, 1 for a digest that doesn't exist.
- actionlint (with shellcheck) and `renovate-config-validator --strict` are clean.
- The issue step only runs on GitHub. After merge, the first `workflow_dispatch` run is its real test.
