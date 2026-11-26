#!/usr/bin/env bash
# scripts/promotion-kind.sh <env> <to-commit>: what promoting <env> to the
# image built from <to-commit> would ship, as Git trailers for the promotion
# commit (read by the patch promoter):
#
#   Promotion-Range: <from>..<to>   main commits since the image <env> runs now
#   Promotion-Kind: patch | feature | unknown
#   Promotion-Feature-PRs: #12 #15  (only for feature: what makes it one)
#
# An image contains every commit on main before the one it was built from,
# so the whole range counts, not just the newest commit. Only main's
# first-parent commits that change app/ change the image (the Dockerfile and
# everything it copies are under app/; app/k6 and Markdown aren't in the
# image, so they don't count; if the build ever reads files outside app/,
# add them to the pathspec at the bottom). The range is a
# patch only if each of those is a merged PR labelled `dependencies` and not
# `needs-owner-approval` (Renovate's patch and digest updates,
# renovate.json5). Anything else, a direct commit or a PR without labels, is
# a feature. `unknown` when the env's current commit isn't on main (then
# nothing may be auto-promoted). Needs git history (fetch-depth: 0) and
# `gh` with read access (GH_TOKEN in CI).
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <dev|staging|prod> <to-commit>" >&2; exit 2; }
env=$1 to=$2
cd "$(dirname "$0")/.."
repo=${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}

# The env's image tag is sha-<12 hex> of the commit it was built from.
tag=$(awk '/^image:[[:space:]]*$/{f=1;next} f&&/^[^ #]/{f=0} f&&/^  tag:/{print $2}' "environments/$env/values.yaml")
from=${tag#sha-}
to=$(git rev-parse --verify "$to^{commit}")

if ! [[ $from =~ ^[0-9a-f]{12}$ ]] || ! from=$(git rev-parse --verify -q "$from^{commit}") ||
   ! git merge-base --is-ancestor "$from" "$to"; then
  echo "Promotion-Range: ${tag:-?}..${to:0:12}"
  echo "Promotion-Kind: unknown"
  exit 0
fi
echo "Promotion-Range: ${from:0:12}..${to:0:12}"

features=()
while read -r c; do
  [ -n "$c" ] || continue
  # The PR this first-parent commit came from (a merge or squash commit).
  # If the API can't answer, nothing in this range is proven a patch:
  # report unknown rather than fail (promote-prs must still open its PR).
  if ! pr=$(gh api "repos/$repo/commits/$c/pulls" --jq '[.[] | select(.merged_at != null)][0] // empty | "\(.number) \([.labels[].name] | join(","))"' 2>/dev/null); then
    echo "Promotion-Kind: unknown"
    exit 0
  fi
  read -r num labels <<<"${pr:-}"
  if [ -z "${num:-}" ]; then
    features+=("${c:0:12}")
  elif [[ ",${labels:-}," == *,dependencies,* && ",${labels:-}," != *,needs-owner-approval,* ]]; then
    : # Renovate patch/digest update
  else
    features+=("#$num")
  fi
done < <(git log --first-parent --format=%H "$from..$to" -- app/ ':(exclude)app/k6' ':(exclude)app/**/*.md' ':(exclude)app/*.md')

if [ "${#features[@]}" -eq 0 ]; then
  echo "Promotion-Kind: patch"
else
  echo "Promotion-Kind: feature"
  echo "Promotion-Feature-PRs: ${features[*]}"
fi
