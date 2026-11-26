#!/usr/bin/env bash
# Scans an app image for known vulnerabilities with Trivy and fails on any
# HIGH or CRITICAL one that has a fix available.
# Exit status: 0 clean, 3 findings, anything else a scanner error (registry
# or DB download), so callers can tell an outage from a real finding. CI runs it on
# pull requests (ci-app.yml) against the image the PR builds.
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
    --exit-code 3 \
    --format table \
    "$1" || rc=$?
  # Keep the worst: an error (anything but 3) outranks findings.
  if [ "${rc:-0}" -ne 0 ]; then
    if [ "$rc" -ne 3 ] || [ "$status" -eq 0 ]; then status=$rc; fi
  fi
  rc=0
done
exit "$status"
