#!/usr/bin/env bash
# ./platform demo hello-world: a second app through the whole local CI/CD,
# narrated step by step. It stays running afterwards, to play with.
# ./platform demo hello-world clean: tear it down again.
#
#   1. Add the app: demo/hello-world/{app,chart,cd} are copied to
#      apps/hello-world, apps/hello-world/chart and apps/hello-world/cd in this checkout.
#   2. CI: ./pipeline ci hello-world --version V (test, build, scan, publish
#      image and chart V to the in-stack registry).
#   3. CD: ./pipeline cd hello-world dev, then staging, then prod. dev syncs
#      by itself; staging and prod use --sync in place of the Sync click.
#   4. A second version W: prod first is refused (staging hasn't run it),
#      then W goes through in order.
#   5. Rollback: ./pipeline rollback hello-world prod, back to V.
#   6. Load and observe: a minute of k6 traffic to prod (load.js), then a
#      Grafana link with its requests (Prometheus) beside its logs (Loki).
#
# Teardown (./platform demo hello-world clean, or ./platform demo clean): the
# three folders are removed and the checkout pushed again, so Argo CD deletes
# hello-world-dev, -staging and -prod. The images stay in the registry
# (harmless). Running the demo again tears down the previous run first.
# Needs a running cluster (./platform up) and the host tools ./pipeline needs
# (Docker, curl).
# Runs on the host, like ./pipeline (it calls it); the other demos run in
# the toolbox. The copied folders are
# hidden from your own git (.git/info/exclude) while they exist, so they
# can't be committed by accident; the in-stack Git server still gets them.
set -eu

cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd)
. scripts/lib/host.sh

APP=hello-world
SRC=demo/hello-world
DIRS="apps/$APP"
MARKER=.build/hello-world-demo
clean_only=''
case "${1:-}" in
  clean) clean_only=1 ;;
  '') ;;
  *) die "usage: ./platform demo hello-world [clean]" ;;
esac

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
say() { printf '  %s\n' "$*"; }
# check <where> <url> <what you should see>...: the same "go and look" box as demo/lib.sh.
check() {
  local where=$1 url=$2 line; shift 2
  printf '  %s▶ Check: %s%s\n' "${CMD:-}" "$where" "${RST:-}"
  [ -z "$url" ] || printf '      %s\n' "$url"
  for line; do printf '      • %s\n' "$line"; done
}
# Every command is printed before it runs ("$ ..."), its output indented below.
if [ -t 1 ]; then CMD=$(printf '\033[36m') RST=$(printf '\033[0m'); else CMD='' RST=''; fi
show() { printf '  %s$ %s%s\n' "$CMD" "$*" "$RST"; }
run() { show "$*"; "$@"; }
kc() { TOOLBOX_EXEC='' run_toolbox kubectl "$@"; }

# Your git's exclude file, if this is a git checkout (a worktree has its own).
exclude_file() { git rev-parse --git-path info/exclude 2>/dev/null || true; }
hide_from_git() {
  f=$(exclude_file); [ -n "$f" ] || return 0
  mkdir -p "$(dirname "$f")"
  { echo "# ./platform demo hello-world (removed when the demo ends)"; for d in $DIRS; do echo "/$d/"; done; } >>"$f"
}
unhide_from_git() {
  f=$(exclude_file); [ -n "$f" ] && [ -f "$f" ] || return 0
  grep -v -e '^# ./platform demo hello-world' -e "^/apps/$APP/\$" "$f" >"$f.tmp" || true
  mv "$f.tmp" "$f"
}

# Remove the copy and push the checkout without it: the ApplicationSet then
# deletes the hello-world Applications, and their finalizers the workloads.
remove_copy() {
  [ -f "$MARKER" ] || return 0
  step "Teardown: remove hello-world from the checkout and from the cluster"
  # shellcheck disable=SC2086
  run rm -rf $DIRS
  unhide_from_git
  show "./platform shell scripts/git-sync.sh   # push the checkout to the in-stack Git server"
  TOOLBOX_EXEC='' run_toolbox bash scripts/git-sync.sh >/dev/null && ok "pushed the checkout without hello-world"
  for _ in $(seq 1 60); do
    kc -n argocd get applications.argoproj.io -o name 2>/dev/null | grep -q "/$APP-" || break
    sleep 3
  done
  if kc -n argocd get applications.argoproj.io -o name 2>/dev/null | grep -q "/$APP-"; then
    rm -f "$MARKER"
    die "Argo CD still has hello-world Applications after 3 minutes: kubectl -n argocd get applications"
  else
    ok "hello-world-dev, -staging and -prod deleted (the images stay in the registry)"
  fi
  rm -f "$MARKER"
}
# Whatever happens, say how to tear it down: a failed or interrupted run
# leaves what it got to, to look at.
on_exit() {
  rc=$?
  [ -f "$MARKER" ] || return 0
  [ "$rc" -eq 0 ] || printf '\n  The demo stopped (exit %s); what it set up is still there to look at.\n' "$rc"
  printf '  Tear it down: ./platform demo hello-world clean\n'
}

# Answers /version with $1 on entrypoint port $2, 5 times in a row (an old
# pod drains for a few seconds after a rollout). Waits up to 60 s.
serves() {
  show "curl -s -H 'Host: $APP.localhost' http://127.0.0.1:$2/version   # until it answers $1 five times in a row"
  n=0
  for _ in $(seq 1 240); do
    v=$(curl -s --max-time 2 -H "Host: $APP.localhost" "http://127.0.0.1:$2/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [ "$v" = "$1" ]; then n=$((n + 1)); [ "$n" -ge 5 ] && break; else n=0; fi
    sleep 0.25
  done
  [ "$n" -ge 5 ] || die "http://$APP.localhost:$2 doesn't answer version $1 (it answers '${v:-nothing}')"
  show "curl -s -H 'Host: $APP.localhost' http://127.0.0.1:$2/"
  ok "http://$APP.localhost:$2 says: $(curl -s -H "Host: $APP.localhost" "http://127.0.0.1:$2/") (version $1)"
}
port_of() { case $1 in prod) echo 8080 ;; dev) echo 8082 ;; staging) echo 8083 ;; esac; }

# The next version not yet published, from $1 up (published versions are
# never overwritten, so a second run of the demo picks new ones).
next_version() {
  v=$1
  while TOOLBOX_EXEC='' run_toolbox bash scripts/registry.sh published "$APP" "$v" >/dev/null 2>&1; do
    v=$(echo "$v" | awk -F. '{print $1"."$2"."$3+1}')
  done
  echo "$v"
}

# --- 0. Preconditions --------------------------------------------------------
check_docker
if [ -n "$clean_only" ]; then
  if [ -f "$MARKER" ]; then remove_copy; else ok "no hello-world demo to tear down"; fi
  exit 0
fi
kc get namespace argocd >/dev/null 2>&1 || die "no cluster: start it with ./platform up (or docker compose up -d --wait)"
for d in $DIRS; do
  [ ! -e "$d" ] || [ -f "$MARKER" ] || die "$d already exists and isn't from this demo: move it away first"
done
[ ! -f "$MARKER" ] || { say "hello-world from a previous run is still there: tearing it down first"; remove_copy; }

trap on_exit EXIT
trap 'exit 130' INT TERM

# --- 1. Add the app ----------------------------------------------------------
step "1 · Add a second app: hello-world"
say "An app here is one folder, apps/<app>: app/ (the code), chart/ (its Helm"
say "chart) and cd/ (what each environment runs). Copying it in is all it"
say "takes; nothing in the platform names orders-gateway."
mkdir -p .build && : >"$MARKER"
hide_from_git
run mkdir -p "apps/$APP"
run cp -R "$SRC/app" "apps/$APP/app"
run cp -R "$SRC/chart" "apps/$APP/chart"
run mkdir -p "apps/$APP/cd"
run cp "$SRC/cd/values.yaml" "apps/$APP/cd/values.yaml"
ok "apps/$APP: app/, chart/, cd/values.yaml (hidden from your git while the demo runs)"

# --- 2. CI -------------------------------------------------------------------
V=$(next_version 0.1.0)
W=$(next_version "$(echo "$V" | awk -F. '{print $1"."$2"."$3+1}')")
step "2 · CI: ./pipeline ci $APP --version $V"
say "Test, build, scan with Trivy, then publish image $APP:$V and chart $APP $V"
say "to the registry in the cluster. A published version is never overwritten."
run ./pipeline ci "$APP" --version "$V"

# --- 3. CD, in order ---------------------------------------------------------
for e in dev staging prod; do
  run cp "$SRC/cd/$e.yaml" "apps/$APP/cd/$e.yaml"
  if [ "$e" = dev ]; then
    step "3 · CD: ./pipeline cd $APP dev --version $V"
    say "dev has autoSync: true, so Argo CD rolls it out as soon as the change"
    say "reaches the in-stack Git server. The ApplicationSet creates $APP-dev"
    say "because apps/$APP/cd/dev.yaml now exists."
    run ./pipeline cd "$APP" dev --version "$V"
  else
    step "3 · CD: ./pipeline cd $APP $e --version $V --sync"
    say "$e only takes a version the environment before it has run, and only"
    say "while that one is healthy (Argo CD Synced and Healthy, no firing alert"
    say "for $APP). autoSync is off here: --sync stands in for the Sync click."
    run ./pipeline cd "$APP" "$e" --version "$V" --sync
  fi
  serves "$V" "$(port_of "$e")"
done
check "Argo CD: hello-world-dev, -staging and -prod" "http://localhost:8081/applications?search=hello-world" \
  "all three Synced and Healthy, each on $V" \
  "open hello-world-staging → History and rollback: the sync names the Git commit ./pipeline made; that commit is the release"

# --- 4. A second version: out of order is refused ----------------------------
step "4 · CI for a second version: ./pipeline ci $APP --version $W"
run ./pipeline ci "$APP" --version "$W"
step "4 · Straight to prod is refused: ./pipeline cd $APP prod --version $W"
if run ./pipeline cd "$APP" prod --version "$W" --sync; then
  die "prod took $W although staging never ran it"
fi
ok "refused, as it should be: promote in order"
for e in dev staging prod; do
  step "4 · ./pipeline cd $APP $e --version $W$([ "$e" = dev ] || echo ' --sync')"
  if [ "$e" = dev ]; then run ./pipeline cd "$APP" dev --version "$W"; else run ./pipeline cd "$APP" "$e" --version "$W" --sync; fi
  serves "$W" "$(port_of "$e")"
done

# --- 5. Rollback -------------------------------------------------------------
step "5 · Rollback: ./pipeline rollback $APP prod --sync"
say "Always allowed, no gate: back to what prod ran before ($V)."
run ./pipeline rollback "$APP" prod --sync
serves "$V" 8080
check "Argo CD: hello-world-prod" "http://localhost:8081/applications/argocd/hello-world-prod" \
  "History and rollback: $V, then $W, then $V again. The rollback is a new Git commit, not a cluster edit"

# --- 6. Load, then observe ---------------------------------------------------
step "6 · A minute of traffic to hello-world in prod, then see it in Grafana"
say "k6 sends 20 requests a second for one minute, so the graphs and logs"
say "have something to show."
show "k6 run demo/hello-world/load.js"
if k6out=$(TOOLBOX_EXEC='' run_toolbox k6 run --quiet --no-color demo/hello-world/load.js 2>&1); then
  printf '%s\n' "$k6out" | grep -E '^ *(checks_succeeded|http_reqs|http_req_failed|http_req_duration)\.\.' | sed 's/^ */    /'
  ok "a minute of traffic, under 1% failed"
else
  printf '%s\n' "$k6out" | sed 's/^/    /'
  die "the load test failed (more than 1% of requests failed): see k6's output above"
fi
q='sum by (namespace) (http_requests_total{service="hello-world"})'
show "kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q'"
# In the toolbox (it has jq): the namespaces with hello-world requests, up to 2 min.
# shellcheck disable=SC2016 # expanded inside the toolbox's bash
found=$(TOOLBOX_EXEC='' run_toolbox bash -c '
  for _ in $(seq 1 24); do
    r=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" "\$q|@uri")" 2>/dev/null |
      jq -r "[.data.result[].metric.namespace] | sort | join(\", \")" 2>/dev/null || true)
    [ -n "$r" ] && { echo "$r"; exit 0; }
    sleep 5
  done' _ "$q" || true)
if [ -n "$found" ]; then ok "Prometheus has hello-world's requests in: $found"; else say "! no hello-world series in Prometheus yet (scrapes run every 30 s)"; fi
# Grafana Explore, split in two: requests per second by status (Prometheus)
# beside the logs (Loki), last 15 minutes. Log in with admin / admin12345.
explore='http://localhost:3000/explore?schemaVersion=1&orgId=1&panes=%7B%22a%22%3A%7B%22datasource%22%3A%22prometheus%22%2C%22queries%22%3A%5B%7B%22refId%22%3A%22A%22%2C%22datasource%22%3A%7B%22type%22%3A%22prometheus%22%2C%22uid%22%3A%22prometheus%22%7D%2C%22expr%22%3A%22sum%20by%20%28status%29%20%28rate%28http_requests_total%7Bnamespace%3D%5C%22prod%5C%22%2C%20service%3D%5C%22hello-world%5C%22%7D%5B1m%5D%29%29%22%7D%5D%2C%22range%22%3A%7B%22from%22%3A%22now-15m%22%2C%22to%22%3A%22now%22%7D%7D%2C%22b%22%3A%7B%22datasource%22%3A%22loki%22%2C%22queries%22%3A%5B%7B%22refId%22%3A%22A%22%2C%22datasource%22%3A%7B%22type%22%3A%22loki%22%2C%22uid%22%3A%22loki%22%7D%2C%22expr%22%3A%22%7Bnamespace%3D%5C%22prod%5C%22%2C%20app%3D%5C%22hello-world%5C%22%7D%20%7C%20json%22%7D%5D%2C%22range%22%3A%7B%22from%22%3A%22now-15m%22%2C%22to%22%3A%22now%22%7D%7D%7D'
say "See it in Grafana (admin / admin12345): requests per second and the logs, side by side:"
say "  $explore"
say "Or type the queries yourself:"
say "  Prometheus    sum by (status) (rate(http_requests_total{namespace=\"prod\", service=\"hello-world\"}[1m]))"
say "  Loki          {namespace=\"prod\", app=\"hello-world\"} | json"
say "Also: the app at http://hello-world.localhost:8080 (prod), :8082 (dev), :8083 (staging);"
say "Argo CD at http://localhost:8081 (hello-world-dev, -staging, -prod)."
say "orders-gateway's SLO alerts count only orders-gateway: hello-world can't"
say "burn its error budget or block its promotions."
step "Done: hello-world went through CI, dev → staging → prod, a refused promotion and a rollback"
say "It stays running: try ./pipeline cd hello-world dev --version $W, scale it,"
say "break it, watch it in Grafana."
