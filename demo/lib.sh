#!/usr/bin/env bash
# Shared by the demos in demo/<name>/run.sh (sourced, not run): k6 load and
# narration, the in-stack Git helpers, and the "Check" boxes.
#
# Every demo runs on a real environment, prod unless you name another:
# Argo CD Application orders-gateway-<env>, namespace <env>, its port (prod
# :8080, dev :8082, staging :8083). They kill its pods, drain a node, scale
# it, switch on its fault and commit to its env file, and each one ends
# with it recovered (or fails saying it didn't). k6 sends ~10 requests/s to
# it the whole time.
# Runs in the toolbox.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
# One output stream, so commands, their output and the narration stay in
# order even when piped (docker keeps stdout and stderr apart without a tty).
exec 2>&1

K6_LOG=/tmp/demo-k6.log

# --- showing the commands ----------------------------------------------------
# Every command a demo runs against the cluster, Git or the app is printed
# first ("$ kubectl ..."), and its output is shown indented below it. All of
# it goes to stderr, so helpers whose stdout is captured stay clean.
if [ -t 2 ]; then CMD=$'\e[36m' DIM=$'\e[2m' RST=$'\e[0m'; else CMD='' DIM='' RST=''; fi
# qargs <args...>: the arguments as you'd type them, quoting only where needed.
qargs() {
  local a out=''
  for a in "$@"; do
    case $a in
      '' | *[!A-Za-z0-9_./:=@,+%-]*) out+=" '${a//\'/\'\\\'\'}'" ;;
      *) out+=" $a" ;;
    esac
  done
  printf '%s' "${out# }"
}
show() { printf '  %s$ %s%s\n' "$CMD" "$*" "$RST" >&2; }  # show <command line as text>
note() { printf '    %s# %s%s\n' "$DIM" "$*" "$RST" >&2; }  # a comment under a command
indent() { sed 's/^/      /' >&2; }
# run <cmd...>: show it, run it, show its output. Fails if the command fails.
run() {
  local shown=("$@")
  [ "$1" != gitauth ] || shown[0]=git # gitauth is git with the in-stack server's key
  show "$(qargs "${shown[@]}")"
  "$@" 2>&1 | indent
}
# get <cmd...>: show it, run it, show its output and also return it on stdout,
# for values a demo needs (x=$(get kubectl ...)).
get() {
  local out
  show "$(qargs "$@")"
  out=$("$@") || return
  printf '%s\n' "$out" | indent
  printf '%s\n' "$out"
}

# The demo's name is its folder. Its one option is the environment it runs
# in: dev, staging or prod (the default).
name=$(basename "$(cd "$(dirname "$0")" && pwd)")
ENV=${1:-prod}
[ $# -le 1 ] || die "usage: ./platform demo $name [dev|staging|prod]"
case $ENV in
  dev) PORT=8082 ;; staging) PORT=8083 ;; prod) PORT=8080 ;;
  *) die "usage: ./platform demo $name [dev|staging|prod] (got '$ENV')" ;;
esac
APP=orders-gateway-$ENV NS=$ENV URL=http://localhost:$PORT
# needs <kind> <what>: stops early when the environment has no orders-gateway
# <kind> (pdb, hpa), so it can't show the demo.
needs() {
  kubectl -n "$NS" get "$1" orders-gateway >/dev/null 2>&1 ||
    die "$name needs $2, which $ENV doesn't have: try ./platform demo $name prod"
}

# Runs on any exit, also Ctrl-C: stop k6, uncordon a node the chaos demo
# cordoned (so an interrupted demo never leaves a node unschedulable), and
# remove the gitops-revert clone.
K6_PID='' CORDONED='' GIT_WORK='' GIT_PF='' GIT_KEYDIR=''
cleanup() {
  [ -z "$K6_PID" ] || kill "$K6_PID" 2>/dev/null || true
  # A demo that changed the environment on purpose undoes it here if it was
  # interrupted. First, while the Git port-forward is still up.
  if declare -F demo_undo >/dev/null; then demo_undo || true; fi
  [ -z "$GIT_PF" ] || kill "$GIT_PF" 2>/dev/null || true
  [ -z "$GIT_KEYDIR" ] || rm -rf "$GIT_KEYDIR"
  if [ -n "$CORDONED" ]; then kubectl uncordon "$CORDONED" >/dev/null 2>&1 || true; fi
  [ -z "$GIT_WORK" ] || rm -rf "$GIT_WORK"
}
trap cleanup EXIT
# Ctrl-C (and docker stop) end the demo through cleanup. Needed: in the toolbox
# container bash is PID 1, which ignores signals it has no trap for.
trap 'exit 130' INT TERM

# --- prod ---------------------------------------------------------------------

# wait_healthy <timeout s>: prod Synced and Healthy in Argo CD, every replica of
# the Deployment updated and available.
wait_healthy() {
  local deadline=$(( $(date +%s) + $1 )) s ready
  show "kubectl -n argocd get applications.argoproj.io $APP -o jsonpath='{.status.sync.status}/{.status.health.status}'"
  show "kubectl -n $NS get deployment orders-gateway -o json   # updated, ready and available replicas"
  note "every 5 s until Synced/Healthy and every replica is up to date (up to ${1}s)"
  while :; do
    s=$(kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
    ready=$(kubectl -n "$NS" get deployment orders-gateway -o json 2>/dev/null |
      jq -r 'select(.status.observedGeneration >= .metadata.generation and (.status.updatedReplicas // 0) == .spec.replicas and (.status.availableReplicas // 0) == .spec.replicas and ((.status.replicas // 0) == .spec.replicas)) | "ok"' || true)
    if [ "$s" = Synced/Healthy ] && [ -n "$ready" ]; then
      ok "$APP is Synced and Healthy, every pod ready"; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "$APP not Synced and Healthy after ${1}s (it shows ${s:-?}); run ./platform verify"
    sleep 5
  done
}

# Older versions of the demos ran on a copy of prod in namespace demo.
# ./platform demo clean removes one left behind.
delete_old_copy() {
  local a
  for a in orders-gateway-demo demo; do
    [ "$(kubectl -n argocd get applications.argoproj.io "$a" -o jsonpath='{.metadata.labels.demo}' 2>/dev/null)" = true ] || continue
    run kubectl -n argocd delete applications.argoproj.io "$a" --wait=true --timeout=180s
    ok "deleted the old demo copy $a"
  done
  if kubectl get namespace demo >/dev/null 2>&1; then
    run kubectl delete namespace demo --wait=true --timeout=180s
    ok "deleted namespace demo"
  fi
}

# --- load and narration ------------------------------------------------------

start_load() { # start_load [requests/s, default 10]
  local rate=${1:-10}
  step "Starting k6: ~$rate requests/s to $URL (log: $K6_LOG)"
  # Argo CD reports Healthy as soon as the pods are ready; Traefik picks up a
  # new Ingress a few seconds later and answers 404 until then.
  local i code=''
  show "curl -s -o /dev/null -w '%{http_code}' $URL/version   # until Traefik answers"
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL/version" || true)
    [ "$code" = 200 ] && break
    sleep 1
  done
  printf '      %s (after %s s)\n' "$code" "$((i - 1))"
  [ "$code" = 200 ] || die "$URL doesn't answer after 60 s (it answers $code): run ./platform verify"
  note "k6 is a load-testing tool (not part of the app); apps/orders-gateway/app/k6/load.js was written for this repo"
  note "its mix: 60% GET /work, 30% POST /echo, 10% GET /version, through Traefik to $ENV"
  show "k6 run --quiet --summary-mode=compact -e BASE_URL=$URL -e RATE=$rate -e DURATION=30m apps/orders-gateway/app/k6/load.js > $K6_LOG 2>&1 &"
  k6 run --quiet --summary-mode=compact \
    -e BASE_URL="$URL" -e RATE="$rate" -e DURATION=30m "$ROOT/apps/orders-gateway/app/k6/load.js" >"$K6_LOG" 2>&1 &
  K6_PID=$!
  sleep 15
  kill -0 "$K6_PID" 2>/dev/null || { cat "$K6_LOG"; die "k6 stopped (see above)"; }
  ok "k6 running (pid $K6_PID)"
}

where_to_watch() {
  echo "  Watch it live:"
  echo "    Argo CD             http://localhost:8081/applications/argocd/$APP"
  echo "    Grafana             $(dash_url orders-gateway "$NS") (admin / admin12345)"
  echo "    Terminal            ./platform shell -c 'kubectl -n $NS get pods -w'"
}

# --- what to look at ---------------------------------------------------------
# dash_url <dashboard uid> [namespace]: a Grafana dashboard, last 30 minutes,
# refreshing every 10 s, with its environment drop-down already set.
dash_url() {
  local u="http://localhost:3000/d/$1?from=now-30m&to=now&refresh=10s"
  [ -z "${2:-}" ] || u+="&var-namespace=$2"
  printf '%s' "$u"
}
# loki_url <LogQL>: Grafana Explore with the query already in, last 30 minutes.
loki_url() {
  printf 'http://localhost:3000/explore?schemaVersion=1&orgId=1&panes=%s' "$(jq -rn --arg e "$1" \
    '{a: {datasource: "loki", queries: [{refId: "A", datasource: {type: "loki", uid: "loki"}, expr: $e}], range: {from: "now-30m", to: "now"}}} | tojson | @uri')"
}
# check <where> <url> <what you should see>...: a "go and look" box, so the
# person running the demo knows which screen to open and what it should show.
check() {
  local where=$1 url=$2 line; shift 2
  printf '  %s▶ Check: %s%s\n' "$CMD" "$where" "$RST"
  [ -z "$url" ] || printf '      %s\n' "$url"
  for line; do printf '      • %s\n' "$line"; done
}

# Stops k6 (SIGINT makes it print its end-of-test summary) and reports the
# SLO rate it measured from the client side.
k6_summary() {
  local slo
  show "kill -INT $K6_PID   # stop k6; it prints its end-of-test summary"
  kill -INT "$K6_PID" 2>/dev/null || true
  wait "$K6_PID" 2>/dev/null || true
  note "k6's summary ($K6_LOG):"
  grep -v -E '^\s*$|test run was aborted' "$K6_LOG" | indent || true
  note "checks: k6's per-request checks (status 200); orders_slo_good: the SLO's definition (not 5xx, /echo and /version under 250 ms)"
  # e.g. "orders_slo_good......: 99.91% 4021 out of 4025"
  slo=$(grep -m1 -E 'orders_slo_good\.+:' "$K6_LOG" | sed -E 's/^[^:]*:[[:space:]]*//' || true)
  ok "k6 sent traffic the whole time; requests meeting the SLO: ${slo:-see $K6_LOG}"
  # shellcheck disable=SC2034 # read by the demos
  SLO_PCT=$(sed -E 's/%.*//' <<<"${slo:-}")
}

# One line per change in the Deployment's rollout: new ReplicaSet ready, old
# ReplicaSet still serving, until every replica runs the new version.
narrate_rolling() { # narrate_rolling <generation before the change> <timeout s>
  local gen0=$1 deadline=$(( $(date +%s) + $2 )) last='' line st
  show "kubectl -n $NS get deployment orders-gateway -o json   # .status: updated, ready, total, unavailable"
  note "every 2 s, one line per change, until every replica runs the new version"
  while :; do
    st=$(kubectl -n "$NS" get deployment orders-gateway -o json 2>/dev/null)
    line=$(jq -r '"updated \(.status.updatedReplicas // 0)/\(.spec.replicas)  ready \(.status.readyReplicas // 0)  total pods \(.status.replicas // 0)  unavailable \(.status.unavailableReplicas // 0)"' <<<"$st")
    if [ "$line" != "$last" ]; then printf '  %s  %s\n' "$(date +%H:%M:%S)" "$line" >&2; last=$line; fi
    # Finished only once a newer generation (the image change) has rolled out.
    if jq -e --argjson g0 "$gen0" 'select(.metadata.generation > $g0 and .status.observedGeneration >= .metadata.generation and (.status.updatedReplicas // 0) == .spec.replicas and (.status.availableReplicas // 0) == .spec.replicas and (.status.replicas // 0) == .spec.replicas)' <<<"$st" >/dev/null; then
      echo finished; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { echo timeout; return 0; }
    sleep 2
  done
}

# --- gitops-revert helpers ---------------------------------------------------

# The in-stack Git server (default mode): Argo CD reads it at
# this URL inside the cluster; from here it's reached over SSH through a
# port-forward, with the bootstrap's key (Secret git/git-admin), as
# scripts/git-sync.sh does. Sets INSTACK_REMOTE.
IN_STACK=http://git.git.svc.cluster.local:23232/platform.git
INSTACK_REMOTE=''
instack_remote() {
  [ -z "$INSTACK_REMOTE" ] || return 0
  local log port=''
  GIT_KEYDIR=$(mktemp -d)
  show "kubectl -n git get secret git-admin -o jsonpath='{.data.private_key}' | base64 -d > $GIT_KEYDIR/key"
  note "the in-stack Git server's SSH key, made by the bootstrap (not printed)"
  kubectl -n git get secret git-admin -o jsonpath='{.data.private_key}' | base64 -d >"$GIT_KEYDIR/key" ||
    die "can't read the in-stack Git server's key (Secret git/git-admin); run ./platform up"
  chmod 600 "$GIT_KEYDIR/key"
  log="$GIT_KEYDIR/pf.log"
  : >"$log" # exists before sed reads it (the backgrounded redirect is late)
  show "kubectl -n git port-forward svc/git :23231 &   # SSH to the Git server Argo CD reads"
  kubectl -n git port-forward svc/git :23231 >"$log" 2>&1 &
  GIT_PF=$!
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$log" | head -1)
    [ -n "$port" ] && break
    sleep 0.5
  done
  [ -n "$port" ] || die "couldn't port-forward to the in-stack Git server: $(cat "$log")"
  export GIT_SSH_COMMAND="ssh -i $GIT_KEYDIR/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  INSTACK_REMOTE="ssh://127.0.0.1:$port/platform.git"
  note "Git remote: $INSTACK_REMOTE (Argo CD sees the same repo as $IN_STACK)"
}

# git against the in-stack server (instack_remote's SSH key does the auth).
gitauth() { git -c safe.directory='*' "$@"; }

# Deletes a branch on <repo> without needing the checkout to be a usable git
# repository (in a worktree checkout /work/.git points outside the mount):
# the push runs from an empty throwaway repository. DRY_RUN=1 only checks
# access (git push --dry-run) and changes nothing.
delete_branch() { # delete_branch <repo url> <branch>
  local tmp rc=0
  tmp=$(mktemp -d)
  show "git push ${DRY_RUN:+--dry-run }$1 --delete $2"
  git -C "$tmp" init -q && gitauth -C "$tmp" push ${DRY_RUN:+--dry-run} "$1" --delete "$2" 2>&1 | indent || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Deletes demo branches older versions of gitops-revert left on the
# in-stack Git server.
clean_branches() {
  local repo b
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
  [ "$repo" = "$IN_STACK" ] || return 0
  instack_remote; repo=$INSTACK_REMOTE
  # Run outside /work: in a git worktree checkout, /work/.git points outside
  # the container's mount and git would refuse to start. ls-remote on a URL
  # needs no repository.
  show "git ls-remote --heads $repo 'demo/gitops-revert-*'"
  for b in $(git -C / ls-remote --heads "$repo" 'demo/gitops-revert-*' 2>/dev/null | awk '{sub("refs/heads/", "", $2); print $2}'); do
    if delete_branch "$repo" "$b"; then ok "${DRY_RUN:+would have }deleted the leftover demo branch $b"
    else warn "couldn't delete the leftover demo branch $b"; fi
  done
}

# 5xx share of the app's requests (/work and /echo) in the environment over the
# last minute, from Prometheus (the same metric the availability SLO uses).
error_ratio() {
  local q="sum(rate(http_requests_total{namespace=\"$NS\",route=~\"/work|/echo\",status=~\"5..\"}[1m])) / sum(rate(http_requests_total{namespace=\"$NS\",route=~\"/work|/echo\"}[1m]))"
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')" 2>/dev/null |
    jq -r '.data.result[0].value[1] // "0" | tonumber * 100 | floor | tostring + "%"' 2>/dev/null || echo "?"
}
# Waits until Argo CD has synced <commit> and the Deployment has rolled out,
# printing the 5xx share every 10 s; then keeps printing it for <settle> s.
narrate_git() { # narrate_git <commit> <settle s> <timeout s>
  local want=$1 settle=$2 deadline=$(( $(date +%s) + $3 )) rev synced_at=''
  run kubectl -n argocd annotate applications.argoproj.io "$APP" argocd.argoproj.io/refresh=normal --overwrite
  note "asks Argo CD to re-read Git now instead of at its next poll"
  show "kubectl -n argocd get applications.argoproj.io $APP -o jsonpath='{.status.sync.revisions}'"
  show "kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=sum(rate(http_requests_total{namespace=\"$NS\",route=~\"/work|/echo\",status=~\"5..\"}[1m])) / sum(rate(http_requests_total{namespace=\"$NS\",route=~\"/work|/echo\"}[1m]))'   # URL-encoded when sent"
  note "every 10 s: which commit Argo CD has synced, and the share of requests failing"
  while :; do
    # One revision per source (the app takes its chart and its values from
    # different places): the Git commit is the one that looks like a SHA.
    rev=$(kubectl -n argocd get applications.argoproj.io "$APP" -o json 2>/dev/null |
      jq -r '[.status.sync.revision // empty, .status.sync.revisions[]?] | map(select(test("^[0-9a-f]{40}$"))) | first // ""')
    if [ -z "$synced_at" ] && [ "$rev" = "$want" ] &&
       kubectl -n "$NS" rollout status deployment/orders-gateway --timeout=1s >/dev/null 2>&1; then
      synced_at=$(date +%s)
      printf '  %s  Argo CD synced %s and the pods rolled out\n' "$(date +%H:%M:%S)" "${want:0:7}" >&2
    fi
    printf '  %s  synced %s   5xx share of /work and /echo (1 min): %s\n' "$(date +%H:%M:%S)" "${rev:0:7}" "$(error_ratio)" >&2
    if [ -n "$synced_at" ] && [ $(( $(date +%s) - synced_at )) -ge "$settle" ]; then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "Argo CD didn't sync ${want:0:7} within ${3}s (it shows ${rev:0:7})"
    sleep 10
  done
}


# --- the app's pods (chaos, autoscale) -----------------------------------

demo_pods() { # name node phase ready, one line per demo pod
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=orders-gateway -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null) |
      "\(.metadata.name) \(.spec.nodeName // "-") \(.status.phase) \(([.status.conditions[]? | select(.type == "Ready") | .status][0]) // "False")"'
}
ready_count() { demo_pods | awk '$4 == "True"' | grep -c . || true; }
show_pods() {
  show "kubectl -n $NS get pods -l app.kubernetes.io/name=orders-gateway -o wide   # + each node's zone label"
  demo_pods | while read -r name node phase ready; do
    zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo -)
    printf '    %-40s %-14s %-7s %s ready=%s\n' "$name" "$node" "$zone" "$phase" "$ready" >&2
  done
}
wait_ready() { # wait_ready <n> <timeout s>
  local deadline=$(( $(date +%s) + $2 )) last='' n
  note "every 2 s: kubectl -n $NS get pods (count the Ready ones) until $1 are ready"
  while :; do
    n=$(ready_count)
    [ "$n" != "$last" ] && { printf '  %s  ready pods: %s\n' "$(date +%H:%M:%S)" "$n" >&2; last=$n; }
    [ "$n" -ge "$1" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || die "only $n of $1 pods ready after ${2}s"
    sleep 2
  done
}

# Every demo ends with this: the environment is still running, and healthy.
finish() {
  wait_healthy 300
  ok "$ENV is serving: $(curl -s --max-time 5 "$URL/version")"
}
