#!/usr/bin/env bash
# Points one environment at an app image: sets image.tag and image.digest in
# environments/<env>/values.yaml, keeping every comment and line around them.
# Promotion is this one Git change (decision 0009); CI runs it for dev on
# every merge to main (.github/workflows/cd-app.yml, job promote-dev).
#   scripts/set-image.sh dev sha-0123456789ab sha256:<64 hex>
# Plain bash + awk, so it runs on a bare CI runner as well as in the toolbox.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <dev|staging|prod> <tag> <sha256:digest>" >&2; exit 2; }
env=$1 tag=$2 digest=$3
file="$(cd "$(dirname "$0")/.." && pwd)/environments/$env/values.yaml"

[ -f "$file" ] || { echo "no such environment: $env ($file)" >&2; exit 2; }
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "not an image tag: $tag" >&2; exit 2; }
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "not a sha256 digest: $digest" >&2; exit 2; }

# Inside the top-level `image:` block only, replace the values of `tag:` and
# `digest:` (two-space indent). Fail unless each was found exactly once, so a
# reshaped file can't be half-updated silently.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk -v tag="$tag" -v digest="$digest" '
  /^[^[:space:]#]/ { inimage = ($0 ~ /^image:[[:space:]]*$/) }
  inimage && /^  tag:/    { sub(/^  tag:.*/, "  tag: " tag); t++ }
  inimage && /^  digest:/ { sub(/^  digest:.*/, "  digest: " digest); d++ }
  { print }
  END { if (t != 1 || d != 1) { printf "expected one image.tag and one image.digest, found %d and %d\n", t, d > "/dev/stderr"; exit 1 } }
' "$file" >"$tmp"
cat "$tmp" >"$file"
echo "$env: image $tag@$digest"
