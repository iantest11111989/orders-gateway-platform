#!/usr/bin/env bash
# Signs app image digests with keyless cosign, then checks what an admission
# policy will rely on: the signature verifies against this workflow's
# identity, and each platform carries an SBOM. CI runs it in the app
# workflow: on main for the published images, and on pull requests against a
# throwaway localhost registry, so a broken signing step fails the PR.
#   IMAGE=ghcr.io/... IDENTITY=https://github.com/<workflow_ref> \
#     scripts/sign-images.sh sha256:... [sha256:...]
# Needs cosign, docker buildx and jq, and a GitHub Actions OIDC token
# (id-token: write) for keyless signing.
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
