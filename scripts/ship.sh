#!/usr/bin/env bash
# The deploy half of ./platform ship / rollback and ./pipeline cd / rollback:
# ship a version of an app, or roll back the last one, by Git change.
#
#   ship [--env ENV] [TAG]    build apps/$APP/ as localhost/$APP:TAG (default
#                             local-YYYYMMDD-HHMMSS), then load + deploy
#   load TAG                  load localhost/$APP:TAG into every kind node
#   deploy [--env ENV] TAG    point cd/$APP/ENV.yaml at localhost/$APP:TAG
#                             (and at chart $CHART too, if CHART is set),
#                             push the checkout to the in-stack Git server and
#                             wait for Argo CD to roll it out
#   chart [--env ENV] VERSION  pin staging or prod to chart VERSION (tag
#                             $APP-chart-VERSION) in cd/$APP/ENV.yaml, push
#                             the same way and wait for it
#   rollback [--env ENV]      put back the image ENV ran before its last image
#                             change (read from the in-stack Git history), then
#                             push the same way
# APP defaults to orders-gateway; ENV to prod for ship/rollback (./pipeline
# always passes it).
#
# Each edits cd/$APP/ENV.yaml in this checkout: the change is a normal file
# change you can see, commit or revert. Not `kubectl rollout undo` or
# `kubectl set image`: Argo CD's self-heal would put Git's version back
# within seconds.
# Needs the default in-stack mode. In GitHub mode, commit the values change
# and push it to GitHub instead. Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN_STACK=http://git.git.svc.cluster.local:23232/platform.git
APP=${APP:-orders-gateway}
LOCAL_REPO=localhost/$APP

cmd=${1:-}; shift || true
env=prod
[ "${1:-}" = --env ] && { env=${2:?"--env needs dev, staging or prod"}; shift 2; }
case "$env" in dev|staging|prod) ;; *) die "--env must be dev, staging or prod" ;; esac
values="$ROOT/cd/$APP/$env.yaml"

in_stack_only() {
  local repo
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
  [ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from ${repo:-?}, not the in-stack Git server: ship and rollback work in the default mode (docker compose up, or ./platform up without REPO_URL). In GitHub mode, change $values, commit and push to GitHub."
}

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

# chartVersion: VERSION in the env file, every other line as it was.
set_chart() { # set_chart <version>
  [ "$env" != dev ] || die "dev runs helm/$APP as it is: only staging and prod pin a chart version"
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || die "not a chart version (semver): '$1'"
  [ "$(grep -c '^chartVersion:' "$values")" = 1 ] || die "expected one chartVersion: line in $values"
  V="$1" awk '/^chartVersion:/ { print "chartVersion: " ENVIRON["V"]; next } { print }' "$values" >"$values.tmp" ||
    { rm -f "$values.tmp"; die "couldn't update chartVersion in $values"; }
  cat "$values.tmp" >"$values" && rm -f "$values.tmp"
  ok "chart $1 (tag $APP-chart-$1)"
}

# Waits until Argo CD has applied chart VERSION to ENV (the Deployment's
# helm.sh/chart label), after git-sync.sh pushed the checkout.
wait_chart() { # wait_chart <version>
  local want="$APP-$1" got deadline=$(( $(date +%s) + 300 ))
  step "Waiting for Argo CD to apply chart $1 to $env"
  while :; do
    got=$(kubectl -n "$env" get deploy app -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>/dev/null || true)
    [ "$got" = "$want" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || { app_status; die "Argo CD hasn't applied chart $1 to $env after 5 minutes (the Deployment shows ${got:-nothing}); see ./platform verify"; }
    sleep 3
  done
  kubectl -n "$env" rollout status deploy/app --timeout=300s
  ok "$env runs chart $1"
}

# On a timeout: what Argo CD says about the environment's Application.
app_status() {
  kubectl -n argocd get applications.argoproj.io "$APP-$env" -o json 2>/dev/null |
    jq -r '"  Argo CD \(.metadata.name): sync \(.status.sync.status // "?"), health \(.status.health.status // "?")",
           (.status.conditions // [] | .[] | "    \(.type): \(.message)"),
           (.status.operationState.message // empty | "    last sync: \(.)")' >&2 || true
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
  [ -z "${CHART:-}" ] || wait_chart "$CHART"
  step "Waiting for Argo CD to roll $env out (Deployment app)"
  local want=$1 deadline=$(( $(date +%s) + 300 ))
  while :; do
    img=$(kubectl -n "$env" get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    [ "$img" = "$want" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || { app_status; die "Argo CD hasn't applied $want to $env/app after 5 minutes (it shows ${img:-nothing}); see ./platform verify"; }
    sleep 3
  done
  kubectl -n "$env" rollout status deploy/app --timeout=300s
  ok "$env runs $want"
  show
}

load() { # load <tag>: the local image into every kind node
  step "Loading $LOCAL_REPO:$1 into the kind nodes (no registry involved)"
  docker image inspect "$LOCAL_REPO:$1" >/dev/null 2>&1 || die "no local image $LOCAL_REPO:$1 (./pipeline ci $APP builds it)"
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" || die "no kind cluster $CLUSTER_NAME: start it with ./platform up"
  kind load docker-image "$LOCAL_REPO:$1" --name "$CLUSTER_NAME" >/dev/null
  ok "loaded into every node"
}

deploy() { # deploy <tag>: point the env file at the local image and roll it out
  step "Pointing $env at it: $values"
  [ -z "${CHART:-}" ] || set_chart "$CHART"
  set_image "$LOCAL_REPO" "$1" ""
  ok "image $LOCAL_REPO:$1 (digest empty: a local build has no registry digest)"
  roll_out "$LOCAL_REPO:$1"
}

case "$cmd" in
  ship)
    in_stack_only
    tag=${1:-local-$(date -u +%Y%m%d-%H%M%S)}
    [[ $tag != latest ]] || die "pick a real tag: :latest is refused in the app namespaces"
    step "Building apps/$APP/ as $LOCAL_REPO:$tag"
    docker build -q -t "$LOCAL_REPO:$tag" --build-arg "VERSION=$tag" "$ROOT/apps/$APP" >/dev/null
    ok "built"
    load "$tag"
    deploy "$tag"
    echo
    if [ "$env" = prod ]; then echo "  Roll back: ./platform rollback" >&2
    else echo "  Roll back: ./platform rollback --env $env" >&2; fi
    ;;
  load)
    load "${1:?usage: ship.sh load TAG}"
    ;;
  deploy)
    in_stack_only
    deploy "${1:?usage: ship.sh deploy [--env ENV] TAG}"
    ;;
  chart)
    in_stack_only
    CHART=${1:?usage: ship.sh chart [--env ENV] VERSION}
    step "Pinning $env to chart $CHART: $values"
    set_chart "$CHART"
    bash "$(dirname "$0")/git-sync.sh"
    wait_chart "$CHART"
    show
    ;;
  rollback)
    in_stack_only
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
    for c in $(git -C "$tmp/r" log --reverse --format=%H -- "cd/$APP/$env.yaml"); do
      imgs+=("$(git -C "$tmp/r" show "$c:cd/$APP/$env.yaml" | norm)")
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
    r=${r:-$(yq '.image.repository' "$ROOT/cd/$APP/values.yaml")}
    ok "back to $r:$t${d:+@${d:0:19}…}"
    want="$r:$t"; [ -z "$d" ] || want="$r@$d"
    roll_out "$want"
    ;;
  *) die "usage: ship.sh ship|deploy [--env dev|staging|prod] [TAG] | chart [--env staging|prod] VERSION | load TAG | rollback [--env dev|staging|prod]" ;;
esac
