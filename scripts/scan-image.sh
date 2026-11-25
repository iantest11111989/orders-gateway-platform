#!/usr/bin/env bash
# Scans an app image for known vulnerabilities with Trivy and fails on any
# HIGH or CRITICAL one that has a fix available (decision 0016). CI runs it in
# the app workflow: on pull requests against the image the PR builds, and on
# main against the published image before dev gets it.
#   TRIVY_IMAGE=ghcr.io/aquasecurity/trivy:<v>@sha256:... \
#     scripts/scan-image.sh <image>@sha256:...
# Set TRIVY_INSECURE=true for a plain-HTTP registry (the PR's localhost one).
# Needs docker; Trivy itself runs from its pinned image.
set -euo pipefail
: "${TRIVY_IMAGE:?TRIVY_IMAGE is the pinned Trivy image}"
[ $# -eq 1 ] || { echo "usage: $0 <image>@sha256:<digest>" >&2; exit 2; }

# Both platforms: given an index, Trivy would scan only the runner's.
# --network host: the PR image is on localhost:5000.
# The vulnerability DB comes from GHCR, with AWS's public mirror as fallback.
status=0
for platform in linux/amd64 linux/arm64; do
  echo "== $platform"
  docker run --rm --network host \
    -e TRIVY_INSECURE="${TRIVY_INSECURE:-false}" \
    -v trivy-cache:/root/.cache/trivy \
    "$TRIVY_IMAGE" image \
    --quiet \
    --platform "$platform" \
    --scanners vuln \
    --db-repository ghcr.io/aquasecurity/trivy-db:2,public.ecr.aws/aquasecurity/trivy-db:2 \
    --skip-java-db-update \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --exit-code 1 \
    --format table \
    "$1" || status=1
done
exit "$status"
