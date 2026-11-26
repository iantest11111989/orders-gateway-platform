#!/usr/bin/env bash
# Signs image digests with keyless cosign, then checks what admission relies
# on: the signature verifies against IDENTITY and each platform has an SBOM.
#   IMAGE=... IDENTITY=https://github.com/<workflow_ref> scripts/sign-images.sh sha256:...
# Needs cosign, docker buildx, jq and a GitHub Actions OIDC token.
set -euo pipefail
: "${IMAGE:?IMAGE is the image repository}"
: "${IDENTITY:?IDENTITY is the expected certificate identity}"
[ $# -gt 0 ] || { echo "usage: $0 <digest>..." >&2; exit 2; }

for d in "$@"; do
  ref="$IMAGE@$d"
  cosign sign --yes "$ref"
  cosign verify "$ref" \
    --certificate-identity "$IDENTITY" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    >/dev/null
  for p in linux/amd64 linux/arm64; do
    docker buildx imagetools inspect "$ref" --format '{{ json .SBOM }}' |
      jq -e --arg p "$p" '.[$p].SPDX.packages | length > 0' >/dev/null ||
      { echo "::error::no SBOM for $p in $ref" >&2; exit 1; }
  done
  echo "signed and verified: $ref"
done
