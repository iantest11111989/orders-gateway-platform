#!/usr/bin/env bash
# The deploy half of ./pipeline cd / rollback: edit cd/$APP/ENV.yaml, push it
# to the in-stack Git server, and wait for Argo CD to roll it out.
#   deploy --env ENV --version V [--force] [--sync]
#         staging/prod take only a version the previous env has run, and the
#         promotion gate must pass; --force skips both.
#   deploy --env dev --tag T     a dev-only build (no version)
#   rollback --env ENV [--sync]  the release ENV ran before its current one
# staging and prod don't auto-sync: without --sync this stops after the push.
# Not `kubectl set image`: Argo CD's self-heal would revert it. Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN_STACK=http://git.git.svc.cluster.local:23232/platform.git
APP=${APP:-orders-gateway}
DEPLOYMENT=${DEPLOYMENT:-$APP}
REPO=localhost:30500/$APP

cmd=${1:-}; shift || true
env='' version='' tag='' force=false sync=false
while [ $# -gt 0 ]; do
  case "$1" in
    --env) env=${2:?--env needs dev, staging or prod}; shift 2 ;;
    --version) version=${2:?--version needs a value}; shift 2 ;;
    --tag) tag=${2:?--tag needs a value}; shift 2 ;;
    --force) force=true; shift ;;
    --sync) sync=true; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done
case "$env" in dev|staging|prod) ;; *) die "--env must be dev, staging or prod" ;; esac
values="$ROOT/cd/$APP/$env.yaml"
[ -f "$values" ] || die "no cd/$APP/$env.yaml"

in_stack_only() {
  local repo
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
  [ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from ${repo:-?}, not the in-stack Git server: start the cluster with ./platform up"
}

# Clone the in-stack repo: its history is what each environment actually ran.
clone_in_stack() {
  [ -d "$tmp/r" ] && return 0
  kubectl -n git port-forward svc/git :23232 >"$tmp/pf" 2>&1 & pf=$!
  local port=''
  for _ in $(seq 1 30); do port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$tmp/pf" | head -1); [ -n "$port" ] && break; sleep 0.5; done
  [ -n "$port" ] || die "couldn't reach the in-stack Git server"
  showcmd "git clone http://127.0.0.1:$port/platform.git   # the in-stack repo Argo CD deploys from"
  git clone -q "http://127.0.0.1:$port/platform.git" "$tmp/r"
}
tmp=$(mktemp -d); pf=''
trap '[ -z "$pf" ] || kill "$pf" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# A comparable release value (ignores key order, quoting, empty digest).
release_of() { yq -o json -I0 '{"version": .version, "image": .image}' | jq -cS '.image |= with_entries(select(.value != "" and .value != null)) | with_entries(select(.value != null))'; }

versions_run_in() { # versions_run_in <env>
  clone_in_stack
  local c
  showcmd "git log --format=%H -- cd/$APP/$1.yaml   # then each commit's version: line"
  for c in $(git -C "$tmp/r" log --format=%H -- "cd/$APP/$1.yaml"); do
    git -C "$tmp/r" show "$c:cd/$APP/$1.yaml" | yq '.version // ""'
  done | grep -v '^$' | sort -u
}

# Edit only the version and image lines, keeping the file's comments and
# layout (yq would reformat it). Rewriting through cat keeps the file's owner
# (the toolbox runs as root).
set_release() { # set_release <version> <repository> <tag> <digest>
  V="$1" REPO="$2" TAG="$3" DIGEST="${4:-\"\"}" awk '
    /^[^[:space:]#]/ { inimage = ($0 ~ /^image:[[:space:]]*$/) }
    NR == FNR { if (inimage && /^  repository:/) hasrepo = 1; if (/^version:/) hasversion = 1; next }
    /^version:/ { if (ENVIRON["V"] != "") print "version: " ENVIRON["V"]; v++; next }
    /^image:[[:space:]]*$/ && !hasversion && ENVIRON["V"] != "" { print "version: " ENVIRON["V"]; print "" }
    inimage && /^  repository:/ { if (ENVIRON["REPO"] != "") print "  repository: " ENVIRON["REPO"]; r++; next }
    inimage && /^  tag:/        { print "  tag: " ENVIRON["TAG"]; t++; next }
    inimage && /^  digest:/     { print "  digest: " ENVIRON["DIGEST"]; d++; next }
    { print }
    /^image:[[:space:]]*$/ { n++; if (!hasrepo && ENVIRON["REPO"] != "") print "  repository: " ENVIRON["REPO"] }
    END { if (n != 1 || t != 1 || d != 1 || r > 1 || v > 1) { printf "expected one image: block with one tag, one digest and at most one repository line, and at most one version line; found %d, %d, %d, %d, %d\n", n, t, d, r, v > "/dev/stderr"; exit 1 } }
  ' "$values" "$values" >"$values.tmp" || { rm -f "$values.tmp"; die "couldn't update $values"; }
  showcmd "diff -u cd/$APP/$env.yaml (before) cd/$APP/$env.yaml (after)"
  diff -u --label "cd/$APP/$env.yaml" --label "cd/$APP/$env.yaml" "$values" "$values.tmp" | sed 's/^/      /' >&2 || true
  cat "$values.tmp" >"$values" && rm -f "$values.tmp"
}

show() { # what the environment serves now
  echo "  Pods running in $env, by version:" >&2
  kubectl -n "$env" get pods -l "app.kubernetes.io/name=$DEPLOYMENT" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running")
            | .metadata.labels["app.kubernetes.io/version"] // "?"] | group_by(.) | .[] | "    \(.[0]): \(length) pod(s)"' >&2 || true
  local q
  q="slo:orders_availability_errors:ratio_rate5m{namespace=\"$env\"}"
  curl -s --max-time 5 "http://localhost:9090/api/v1/query" --data-urlencode "query=$q" |
    jq -r '.data.result[0].value[1] // empty | tonumber * 100 | "  5xx share, last 5 min: \(. * 100 | round / 100)%"' >&2 || true
}

app_status() {
  kubectl -n argocd get applications.argoproj.io "$APP-$env" -o json 2>/dev/null |
    jq -r '"  Argo CD \(.metadata.name): sync \(.status.sync.status // "?"), health \(.status.health.status // "?")",
           (.status.conditions // [] | .[] | "    \(.type): \(.message)"),
           (.status.operationState.message // empty | "    last sync: \(.)")' >&2 || true
}

# Returns 0 for a manual-sync app once Argo CD has read the new commit.
manual_sync() {
  local app="$APP-$env" deadline=$(( $(date +%s) + 60 ))
  [ -z "$(kubectl -n argocd get applications.argoproj.io "$app" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)" ] || return 1
  # git-sync.sh asked for a refresh; Argo CD drops the annotation when done.
  while [ -n "$(kubectl -n argocd get applications.argoproj.io "$app" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}' 2>/dev/null)" ] &&
        [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
}

roll_out() { # roll_out <image>: push the checkout, then wait for the Deployment
  showcmd "scripts/git-sync.sh   # commit the checkout and push it to the in-stack Git server"
  bash "$(dirname "$0")/git-sync.sh"
  if manual_sync; then
    if $sync; then
      sync_app "$APP-$env" && ok "sync of $APP-$env started (--sync)"
    else
      echo
      echo "  auto-sync is off for $APP-$env: click Sync at http://localhost:8081"
      echo "  (admin / admin12345), or rerun with --sync."
      exit 0
    fi
  fi
  step "Waiting for Argo CD to roll $env out (Deployment $DEPLOYMENT)"
  local want=$1 img deadline=$(( $(date +%s) + 300 ))
  showcmd "kubectl -n $env get deploy $DEPLOYMENT -o jsonpath='{.spec.template.spec.containers[0].image}'"
  shownote "every 3 s until Argo CD has applied $want"
  while :; do
    img=$(kubectl -n "$env" get deploy "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
    [ "$img" = "$want" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || { app_status; die "Argo CD hasn't applied $want to $env/$DEPLOYMENT after 5 minutes (it shows ${img:-nothing}); see ./platform verify"; }
    sleep 3
  done
  showcmd "kubectl -n $env rollout status deploy/$DEPLOYMENT --timeout=300s"
  kubectl -n "$env" rollout status "deploy/$DEPLOYMENT" --timeout=300s 2>&1 | sed 's/^/      /'
  # Then wait for pruning (PruneLast) so the next promotion's gate sees Synced.
  local st deadline2=$(( $(date +%s) + 300 ))
  showcmd "kubectl -n argocd get applications.argoproj.io $APP-$env -o jsonpath='{.status.sync.status} {.status.operationState.phase}'"
  shownote "until Synced Succeeded (old objects pruned)"
  while :; do
    st=$(kubectl -n argocd get applications.argoproj.io "$APP-$env" -o jsonpath='{.status.sync.status} {.status.operationState.phase}' 2>/dev/null || true)
    [ "$st" = "Synced Succeeded" ] && break
    [ "$(date +%s)" -lt "$deadline2" ] || { app_status; die "$APP-$env isn't Synced after its sync (it shows: ${st:-nothing}); see ./platform verify"; }
    sleep 3
  done
  ok "$env runs $want"
  show
}

image_ref() { # image_ref <repository> <tag> <digest>
  if [ -n "$3" ]; then echo "$1@$3"; else echo "$1:$2"; fi
}

case "$cmd" in
  deploy)
    in_stack_only
    if [ -n "$tag" ]; then
      [ -z "$version" ] || die "--tag and --version together: a deploy is one or the other"
      [ "$env" = dev ] || die "$tag is a dev-only build: staging and prod take only published versions (./pipeline ci $APP --version X)"
      d=$(bash "$(dirname "$0")/registry.sh" digest "$APP" "$tag")
      step "Pointing dev at the dev-only build $REPO:$tag: $values"
      set_release "" "$REPO" "$tag" "$d"
      ok "no version (Argo CD renders helm/$APP from Git), image $REPO:$tag"
      roll_out "$(image_ref "$REPO" "$tag" "$d")"
      exit 0
    fi
    [ -n "$version" ] || die "deploy needs --version or --tag"
    bash "$(dirname "$0")/registry.sh" published "$APP" "$version" ||
      die "$APP $version isn't published: ./pipeline ci $APP --version $version"
    from=''
    case "$env" in staging) from=dev ;; prod) from=staging ;; esac
    if [ -n "$from" ]; then
      if $force; then
        warn "--force: not checking that $from ran $version, nor the promotion gate"
      else
        step "Has $from run $APP $version? (in-stack history of cd/$APP/$from.yaml)"
        versions_run_in "$from" | grep -qxF "$version" ||
          die "$from has never run $APP $version: promote in order (dev, staging, prod), or --force"
        ok "yes"
        gate="$(dirname "$0")/promotion-gate.sh"
        [ -f "$gate" ] || die "no scripts/promotion-gate.sh: the promotion gate can't run, so nothing is promoted (--force overrides)"
        bash "$gate" "$APP" "$env" || die "the promotion gate refused $APP into $env (reasons above); --force overrides"
      fi
    fi
    d=$(bash "$(dirname "$0")/registry.sh" digest "$APP" "$version")
    step "Pointing $env at $APP $version: $values"
    set_release "$version" "$REPO" "$version" "$d"
    ok "version $version (image $REPO:$version@${d:0:19}…, chart $APP $version)"
    roll_out "$(image_ref "$REPO" "$version" "$d")"
    ;;
  rollback)
    in_stack_only
    step "Finding $env's previous release in the in-stack Git history"
    clone_in_stack
    # Go back from where the current release *first* appeared, so repeated
    # rollbacks walk further back instead of toggling.
    cur=$(release_of <"$values")
    rels=()
    for c in $(git -C "$tmp/r" log --reverse --format=%H -- "cd/$APP/$env.yaml"); do
      rels+=("$(git -C "$tmp/r" show "$c:cd/$APP/$env.yaml" | release_of)")
    done
    first=-1
    for i in "${!rels[@]}"; do [ "${rels[$i]}" = "$cur" ] && { first=$i; break; }; done
    [ "$first" -ge 0 ] || die "$env's current release isn't in the in-stack history; push the checkout first (./platform up)"
    prev=''
    for (( i = first - 1; i >= 0; i-- )); do
      [ "${rels[$i]}" != "$cur" ] && { prev=${rels[$i]}; break; }
    done
    [ -n "$prev" ] || die "$env runs the oldest release in the in-stack history: nothing earlier to roll back to"
    v=$(jq -r '.version // ""' <<<"$prev")
    r=$(jq -r '.image.repository // ""' <<<"$prev")
    t=$(jq -r '.image.tag' <<<"$prev"); d=$(jq -r '.image.digest // ""' <<<"$prev")
    set_release "$v" "$r" "$t" "$d"
    r=${r:-$(yq '.image.repository' "$ROOT/cd/$APP/values.yaml")}
    ok "back to ${v:+version $v, }$r:$t${d:+@${d:0:19}…}"
    roll_out "$(image_ref "$r" "$t" "$d")"
    ;;
  *) die "usage: ship.sh deploy --env ENV (--version V [--force] | --tag T) [--sync] | rollback --env ENV [--sync]" ;;
esac
