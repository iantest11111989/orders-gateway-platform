#!/usr/bin/env bash
# ./platform demo release [staging|prod]: ship a new version of orders-gateway
# the way a real release goes, under traffic:
#   1. CI: ./pipeline ci orders-gateway --version <next>
#   2. dev: ./pipeline cd ... dev. dev has auto-sync on, so it rolls out by
#      itself.
#   3. staging, then prod: ./pipeline cd ... <env> puts the version in Git,
#      and the demo stops at the Sync point: Argo CD shows the env
#      OutOfSync, its pods still run the old version. Nothing changes until
#      someone presses Sync. Then --sync, and the pods roll one at a time.
# k6 sends traffic to the last environment the whole time, and the demo fails
# if fewer than 99.5% of requests meet the SLO. The new version stays
# released; the demo prints the rollback. Runs on the host, because it drives
# ./pipeline. RELEASE_PAUSE (seconds, default 30) is how long it holds at
# each Sync point.
set -eu

cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd)
. scripts/lib/host.sh

APP=orders-gateway
TARGET=${1:-prod}
case $TARGET in staging | prod) ;; *) die "usage: ./platform demo release [staging|prod] (got '$TARGET')" ;; esac
PAUSE=${RELEASE_PAUSE:-30}
K6_LOG=.build/release-k6.log K6_PID=''

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
say() { printf '  %s\n' "$*"; }
if [ -t 1 ]; then CMD=$(printf '\033[36m') RST=$(printf '\033[0m'); else CMD='' RST=''; fi
show() { printf '  %s$ %s%s\n' "$CMD" "$*" "$RST"; }
run() { show "$*"; "$@"; }
kc() { TOOLBOX_EXEC='' run_toolbox kubectl "$@"; }
# check <where> <url> <what you should see>...: the same "go and look" box as demo/lib.sh.
check() {
  local where=$1 url=$2 line; shift 2
  printf '  %s▶ Check: %s%s\n' "$CMD" "$where" "$RST"
  [ -z "$url" ] || printf '      %s\n' "$url"
  for line; do printf '      • %s\n' "$line"; done
}
dash() { printf 'http://localhost:3000/d/orders-gateway?from=now-30m&to=now&refresh=10s&var-namespace=%s' "$1"; }
port_of() { case $1 in prod) echo 8080 ;; dev) echo 8082 ;; staging) echo 8083 ;; esac; }
version_in() { sed -n 's/^version:[[:space:]]*//p' "apps/$APP/cd/$1.yaml" | head -1; }
serving() { curl -s --max-time 3 "http://localhost:$(port_of "$1")/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }

# The next version not yet published, from $1 up (published versions are
# never overwritten, so each run of the demo ships a new one).
next_version() {
  local v=$1
  while TOOLBOX_EXEC='' run_toolbox bash scripts/registry.sh published "$APP" "$v" >/dev/null 2>&1; do
    v=$(echo "$v" | awk -F. '{print $1"."$2"."$3+1}')
  done
  echo "$v"
}

stop_load() {
  [ -n "$K6_PID" ] || return 0
  kill -INT "$K6_PID" 2>/dev/null || true
  wait "$K6_PID" 2>/dev/null || true
  K6_PID=''
}
trap stop_load EXIT
trap 'exit 130' INT TERM

# --- 0. Preconditions --------------------------------------------------------
check_docker
kc get namespace argocd >/dev/null 2>&1 || die "no cluster: start it with ./platform up (or docker compose up -d --wait)"
OLD=$(version_in "$TARGET")
V=$(next_version "$(echo "${OLD:-0.1.0}" | awk -F. '{print $1"."$2"."$3+1}')")
URL=http://localhost:$(port_of "$TARGET")

step "Demo: release orders-gateway $V, dev → staging$([ "$TARGET" = prod ] && echo ' → prod'), under traffic"
say "$TARGET runs ${OLD:-?} now (it answers $(serving "$TARGET")). A release is a change in Git:"
say "./pipeline cd writes the version into apps/$APP/cd/<env>.yaml and pushes it to the"
say "Git server Argo CD deploys from. dev applies it by itself; staging and prod"
say "wait for someone to press Sync. That Sync is the release decision."

mkdir -p .build
step "Starting k6: ~10 requests/s to $TARGET ($URL) for the whole release (log: $K6_LOG)"
show "k6 run --quiet --summary-mode=compact -e BASE_URL=$URL -e RATE=10 -e DURATION=30m apps/$APP/app/k6/load.js &"
TOOLBOX_EXEC='' run_toolbox k6 run --quiet --summary-mode=compact -e BASE_URL="$URL" -e RATE=10 -e DURATION=30m \
  "apps/$APP/app/k6/load.js" >"$K6_LOG" 2>&1 &
K6_PID=$!
sleep 10
kill -0 "$K6_PID" 2>/dev/null || { cat "$K6_LOG"; die "k6 stopped (see above)"; }
ok "k6 running"
check "Grafana, orders-gateway dashboard (environment $TARGET), for the whole demo" "$(dash "$TARGET")" \
  "Pods by version: every pod on ${OLD:-the old version} now; at the end they hand over to $V one at a time" \
  "/work and /echo: share failing with 5xx: stays at 0 through the release"

# --- 1. CI -------------------------------------------------------------------
step "1 · CI: ./pipeline ci $APP --version $V"
say "Tests, builds, scans and publishes image and chart $V to the in-cluster registry."
run ./pipeline ci "$APP" --version "$V"

# --- 2. dev ------------------------------------------------------------------
step "2 · dev: ./pipeline cd $APP dev --version $V"
say "dev has auto-sync on: Argo CD applies the change as soon as it reaches Git."
run ./pipeline cd "$APP" dev --version "$V"
ok "dev answers $(serving dev)"
check "Argo CD, $APP-dev" "http://localhost:8081/applications/argocd/$APP-dev" \
  "Synced and Healthy on $V, with no one pressing anything: that's auto-sync"

# --- 3. staging and prod: the Sync point -------------------------------------
envs=staging; [ "$TARGET" = prod ] && envs="staging prod"
n=3
for e in $envs; do
  step "$n · $e: ./pipeline cd $APP $e --version $V   (no --sync)"
  say "The gate first checks the environment before it runs $V, Synced and Healthy,"
  say "with no alert firing. Then the version goes into Git."
  run ./pipeline cd "$APP" "$e" --version "$V"

  step "$n · The Sync point: Git says $V, $e still runs $(serving "$e")"
  run git --no-pager diff --stat -- "apps/$APP/cd/$e.yaml" || true
  show "kubectl -n argocd get applications.argoproj.io $APP-$e   # sync and health"
  kc -n argocd get applications.argoproj.io "$APP-$e" -o jsonpath='      {.status.sync.status}  {.status.health.status}{"\n"}' || true
  say "OutOfSync: the change is in Git, but $e hasn't moved. Auto-sync is off here,"
  say "so nothing reaches $e until someone presses Sync. In a real team this is where"
  say "the release is reviewed: what changes, and is now a good time."
  check "Argo CD, $APP-$e: the release waiting for its Sync" "http://localhost:8081/applications/argocd/$APP-$e" \
    "the tile is yellow, OutOfSync: Git and the cluster disagree" \
    "APP DIFF shows exactly what Sync would change: the image tag and digest, and the version label" \
    "the SYNC button is the release. The demo presses it for you in ${PAUSE} s"
  check "Grafana, orders-gateway dashboard (environment $e)" "$(dash "$e")" \
    "Pods by version: still all on the old version. Git changing moved nothing"
  [ "$PAUSE" -le 0 ] || { say "Holding ${PAUSE} s so you can look..."; sleep "$PAUSE"; }

  step "$n · Sync: ./pipeline cd $APP $e --version $V --sync"
  say "--sync does what the Sync button does, then waits for the rollout: one new pod"
  say "at a time, each ready before an old one stops."
  run ./pipeline cd "$APP" "$e" --version "$V" --sync
  ok "$e answers $(serving "$e")"
  check "Grafana, orders-gateway dashboard (environment $e)" "$(dash "$e")" \
    "Pods by version: the old version's line steps down as $V's steps up, one pod at a time" \
    "In-flight requests and ready pods: ready pods never drop during the rollout"
  n=$((n + 1))
done

# --- the result --------------------------------------------------------------
step "Result"
stop_load
show "k6's summary ($K6_LOG)"
grep -E 'orders_slo_good|http_reqs|http_req_failed' "$K6_LOG" | sed 's/^ */    /' || true
slo=$(grep -m1 -E 'orders_slo_good\.+:' "$K6_LOG" | sed -E 's/^[^:]*:[[:space:]]*//; s/%.*//' || true)
awk -v p="${slo:-0}" 'BEGIN { exit !(p >= 99.5) }' ||
  die "requests failed during the release: only ${slo:-?}% met the SLO (want >= 99.5%)"
ok "released $V to $TARGET under traffic; ${slo}% of requests met the SLO (>= 99.5%)"
say "The release stays: your checkout's apps/$APP/cd/*.yaml now say $V (git diff shows it),"
say "and the in-cluster Git server has the same commits Argo CD deployed."
say "Roll back: ./pipeline rollback $APP $TARGET --sync"
