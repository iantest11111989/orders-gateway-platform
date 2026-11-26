#!/usr/bin/env bash
# ./platform ship [--env ENV] [TAG] / ./platform rollback [--env ENV]: ship a
# new version of the app, or roll back the last one, by Git change. ENV
# defaults to prod.
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
# Needs the default in-stack mode. In GitHub mode, commit the
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

# Change only the image lines of the values file, leaving every other line,
# blank line and comment as it was (like scripts/set-image.sh). A yq rewrite
# reformatted the whole file, so ship then rollback left the checkout differing
# from Git and the next git pull of a promotion conflicted.
# repository: an empty value removes the line, so the chart's default applies
# (rollback to an image that came from Git, whose file has no repository line).
# The new line goes right after `image:`. digest: an empty value is written
# as "" (a local build has no registry digest).
# Rewriting through cat keeps the file owned by you (the toolbox is root).
set_image() { # set_image <repository> <tag> <digest>
  # Two passes over the file: the first only notes whether image: already has
  # a repository line; the second writes the result.
  REPO="$1" TAG="$2" DIGEST="${3:-\"\"}" awk '
    /^[^[:space:]#]/ { inimage = ($0 ~ /^image:[[:space:]]*$/) }
    NR == FNR { if (inimage && /^  repository:/) hasrepo = 1; next }
    inimage && /^  repository:/ { if (ENVIRON["REPO"] != "") print "  repository: " ENVIRON["REPO"]; r++; next }
    inimage && /^  tag:/        { print "  tag: " ENVIRON["TAG"]; t++; next }
    inimage && /^  digest:/     { print "  digest: " ENVIRON["DIGEST"]; d++; next }
    { print }
    /^image:[[:space:]]*$/ { n++; if (!hasrepo && ENVIRON["REPO"] != "") print "  repository: " ENVIRON["REPO"] }
    END { if (n != 1 || t != 1 || d != 1 || r > 1) { printf "expected one image: block with one tag, one digest and at most one repository line; found %d, %d, %d, %d\n", n, t, d, r > "/dev/stderr"; exit 1 } }
  ' "$values" "$values" >"$values.tmp" || { rm -f "$values.tmp"; die "couldn't update the image lines in $values"; }
  cat "$values.tmp" >"$values" && rm -f "$values.tmp"
}

show() { # what prod serves now, and its 5-minute availability SLO
  # Running pods only (from the API server): counting app_info series in
  # Prometheus would include pods that just terminated, until they go stale.
  echo "  Pods running in $env, by version:" >&2
  kubectl -n "$env" get pods -l app.kubernetes.io/name=app -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")
            | .metadata.labels["app.kubernetes.io/version"] // "?"] | group_by(.) | .[] | "    \(.[0]): \(length) pod(s)"' >&2 || true
  local q
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
    [[ $tag != latest ]] || die "pick a real tag: :latest is refused in the app namespaces"
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
    if [ "$env" = prod ]; then echo "  Roll back: ./platform rollback" >&2
    else echo "  Roll back: ./platform rollback --env $env" >&2; fi
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
    # The image before the current one *first* appeared: so a second rollback
    # goes further back instead of toggling to the build just rolled back
    # from (v0, v1, v2, rollback -> v1, rollback -> v0).
    # Compare image blocks by value: key order, quoting and an empty digest
    # vs none don't make two images different.
    norm() { yq -o json -I0 '.image' | jq -cS 'with_entries(select(.value != "" and .value != null))'; }
    cur=$(norm <"$values")
    imgs=()
    for c in $(git -C "$tmp/r" log --reverse --format=%H -- "environments/$env/values.yaml"); do
      imgs+=("$(git -C "$tmp/r" show "$c:environments/$env/values.yaml" | norm)")
    done
    first=-1
    for i in "${!imgs[@]}"; do [ "${imgs[$i]}" = "$cur" ] && { first=$i; break; }; done
    prev=''
    for (( i = first - 1; i >= 0; i-- )); do
      [ "${imgs[$i]}" != "$cur" ] && { prev=${imgs[$i]}; break; }
    done
    [ "$first" -ge 0 ] || die "$env's current image isn't in the in-stack history; push the checkout first (./platform up)"
    [ -n "$prev" ] || die "$env runs the oldest image in the in-stack history: nothing earlier to roll back to"
    # Put back the repository line as that commit had it: none means the
    # chart's default, so ship then rollback leaves the file as Git has it.
    r=$(jq -r '.repository // ""' <<<"$prev")
    t=$(jq -r '.tag' <<<"$prev"); d=$(jq -r '.digest // ""' <<<"$prev")
    set_image "$r" "$t" "$d"
    r=${r:-$(yq '.image.repository' "$ROOT/charts/orders-gateway/values.yaml")}
    ok "back to $r:$t${d:+@${d:0:19}…}"
    want="$r:$t"; [ -z "$d" ] || want="$r@$d"
    roll_out "$want"
    ;;
  *) die "usage: ./platform ship [--env dev|staging|prod] [TAG] | ./platform rollback [--env dev|staging|prod]" ;;
esac
