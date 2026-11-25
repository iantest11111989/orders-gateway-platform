#!/usr/bin/env bash
# ./platform ship [--env ENV] [TAG] / ./platform rollback [--env ENV]: ship a
# new version of the app, or roll back the last one, by Git change (decision
# 0030). ENV defaults to prod.
#
#   ship      build app/ as localhost/orders-gateway:TAG (default
#             local-YYYYMMDD-HHMMSS), load it into every kind node, point
#             environments/ENV/values.yaml at it, push the checkout to the
#             in-stack Git server; Argo CD rolls it out
#   rollback  put back the image ENV ran before its last image change (read
#             from the in-stack Git history), then push the same way
#
# Both edit environments/ENV/values.yaml in this checkout: the change is a
# normal file change you can see, commit or revert. Not `kubectl rollout
# undo` or `kubectl set image`: Argo CD's self-heal would put Git's version
# back within seconds.
# Needs the default in-stack mode (decision 0029). In GitHub mode, commit the
# values change and push it to GitHub instead. Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN_STACK=http://git.git.svc.cluster.local:23232/platform.git
LOCAL_REPO=localhost/orders-gateway

cmd=${1:-}; shift || true
env=prod
[ "${1:-}" = --env ] && { env=${2:?"--env needs dev, staging or prod"}; shift 2; }
case "$env" in dev|staging|prod) ;; *) die "--env must be dev, staging or prod" ;; esac
values="$ROOT/environments/$env/values.yaml"

repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
[ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from ${repo:-?}, not the in-stack Git server: ship and rollback work in the default mode (docker compose up, or ./platform up without REPO_URL). In GitHub mode, change $values, commit and push to GitHub."

# Write the image block into the values file in place (the toolbox is root;
# rewriting keeps the file owned by you, which yq -i's rename wouldn't).
set_image() { # set_image <repository> <tag> <digest>
  REPO="$1" TAG="$2" DIGEST="$3" yq '.image.repository = strenv(REPO) | .image.tag = strenv(TAG) | .image.digest = strenv(DIGEST)' \
    "$values" >"$values.tmp" && cat "$values.tmp" >"$values" && rm -f "$values.tmp"
}

show() { # what prod serves now, and its 5-minute availability SLO
  local q
  echo "  Pods by version in $env (app_info):" >&2
  q="count by (version) (app_info{namespace=\"$env\"})"
  curl -s --max-time 5 "http://localhost:9090/api/v1/query" --data-urlencode "query=$q" |
    jq -r '.data.result[]? | "    \(.metric.version): \(.value[1]) pod(s)"' >&2 || true
  q="slo:orders_availability_errors:ratio_rate5m{namespace=\"$env\"}"
  curl -s --max-time 5 "http://localhost:9090/api/v1/query" --data-urlencode "query=$q" |
    jq -r '.data.result[0].value[1] // empty | tonumber * 100 | "  5xx share, last 5 min: \(. * 100 | round / 100)%"' >&2 || true
  if [ "$env" = prod ]; then
    echo "  http://localhost:8080/version: $(curl -s --max-time 5 http://localhost:8080/version || echo unreachable)" >&2
  fi
}

roll_out() { # push the checkout, then wait for the Deployment
  bash "$(dirname "$0")/git-sync.sh"
  step "Waiting for Argo CD to roll $env out (Deployment app)"
  local want=$1 deadline=$(( $(date +%s) + 300 ))
  while :; do
    img=$(kubectl -n "$env" get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    [ "$img" = "$want" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || die "Argo CD hasn't applied $want to $env/app after 5 minutes (it shows ${img:-nothing}); see ./platform verify"
    sleep 3
  done
  kubectl -n "$env" rollout status deploy/app --timeout=300s
  ok "$env runs $want"
  show
}

case "$cmd" in
  ship)
    tag=${1:-local-$(date -u +%Y%m%d-%H%M%S)}
    [[ $tag != latest ]] || die "pick a real tag: :latest is refused in the app namespaces (decision 0022)"
    step "Building app/ as $LOCAL_REPO:$tag"
    docker build -q -t "$LOCAL_REPO:$tag" --build-arg "VERSION=$tag" "$ROOT/app" >/dev/null
    ok "built"
    step "Loading it into the kind nodes (no registry involved)"
    kind load docker-image "$LOCAL_REPO:$tag" --name "$CLUSTER_NAME" >/dev/null
    ok "loaded into every node"
    step "Pointing $env at it: $values"
    set_image "$LOCAL_REPO" "$tag" ""
    ok "image $LOCAL_REPO:$tag (digest empty: a local build has no registry digest)"
    roll_out "$LOCAL_REPO:$tag"
    echo
    echo "  Roll back: ./platform rollback${env:+ --env $env}" >&2
    ;;
  rollback)
    step "Finding $env's previous image in the in-stack Git history"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    kubectl -n git port-forward svc/git :23232 >"$tmp/pf" 2>&1 & pf=$!
    trap 'kill $pf 2>/dev/null; rm -rf "$tmp"' EXIT
    port=''
    for _ in $(seq 1 30); do port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$tmp/pf" | head -1); [ -n "$port" ] && break; sleep 0.5; done
    [ -n "$port" ] || die "couldn't reach the in-stack Git server"
    git clone -q "http://127.0.0.1:$port/platform.git" "$tmp/r"
    # The image block at each commit that touched the file, newest first; the
    # first one different from the current one is what to go back to.
    cur=$(yq -o json -I0 '.image' "$values")
    prev=''
    for c in $(git -C "$tmp/r" log --format=%H -- "environments/$env/values.yaml"); do
      img=$(git -C "$tmp/r" show "$c:environments/$env/values.yaml" | yq -o json -I0 '.image')
      if [ "$img" != "$cur" ]; then prev=$img; break; fi
    done
    [ -n "$prev" ] || die "no earlier image for $env in the in-stack history"
    r=$(jq -r '.repository // "ghcr.io/iantest11111989/orders-gateway"' <<<"$prev")
    t=$(jq -r '.tag' <<<"$prev"); d=$(jq -r '.digest // ""' <<<"$prev")
    ok "back to $r:$t${d:+@${d:0:19}…}"
    set_image "$r" "$t" "$d"
    want="$r:$t"; [ -z "$d" ] || want="$r@$d"
    roll_out "$want"
    ;;
  *) die "usage: ./platform ship [--env dev|staging|prod] [TAG] | ./platform rollback [--env dev|staging|prod]" ;;
esac
