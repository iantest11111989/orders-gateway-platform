#!/usr/bin/env bash
# ./platform demo hello-world: a second app through the whole local CI/CD,
# narrated step by step. It stays running afterwards, to play with.
# ./platform demo hello-world clean: tear it down again.
#
#   1. Add the app: demo/hello-world/{app,chart,cd} are copied to
#      apps/hello-world, helm/hello-world and cd/hello-world in this checkout.
#   2. CI: ./pipeline ci hello-world --version V (test, build, scan, publish
#      image and chart V to the in-stack registry).
#   3. CD: ./pipeline cd hello-world dev, then staging, then prod. dev syncs
#      by itself; staging and prod use --sync in place of the Sync click.
#   4. A second version W: prod first is refused (staging hasn't run it),
#      then W goes through in order.
#   5. Rollback: ./pipeline rollback hello-world prod, back to V.
#   6. Observe: hello-world answers at http://hello-world.localhost:<port>,
#      its metrics are in Prometheus (service="hello-world") and its logs in
#      Loki ({app="hello-world"}), next to orders-gateway's.
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
DIRS="apps/$APP helm/$APP cd/$APP"
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
  grep -v -e '^# ./platform demo hello-world' -e "^/apps/$APP/\$" -e "^/helm/$APP/\$" -e "^/cd/$APP/\$" "$f" >"$f.tmp" || true
  mv "$f.tmp" "$f"
}

# Remove the copy and push the checkout without it: the ApplicationSet then
# deletes the hello-world Applications, and their finalizers the workloads.
remove_copy() {
  [ -f "$MARKER" ] || return 0
  step "Teardown: remove hello-world from the checkout and from the cluster"
  # shellcheck disable=SC2086
  rm -rf $DIRS
  unhide_from_git
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
  n=0
  for _ in $(seq 1 240); do
    v=$(curl -s --max-time 2 -H "Host: $APP.localhost" "http://127.0.0.1:$2/version" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
    if [ "$v" = "$1" ]; then n=$((n + 1)); [ "$n" -ge 5 ] && break; else n=0; fi
    sleep 0.25
  done
  [ "$n" -ge 5 ] || die "http://$APP.localhost:$2 doesn't answer version $1 (it answers '${v:-nothing}')"
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
say "An app here is three folders: apps/<app> (the code), helm/<app> (the"
say "chart) and cd/<app> (what each environment runs). Copying them in is all"
say "it takes; nothing in the platform names orders-gateway."
mkdir -p .build && : >"$MARKER"
hide_from_git
cp -R "$SRC/app" "apps/$APP"
cp -R "$SRC/chart" "helm/$APP"
mkdir -p "cd/$APP" && cp "$SRC/cd/values.yaml" "cd/$APP/values.yaml"
ok "apps/$APP, helm/$APP, cd/$APP/values.yaml (hidden from your git while the demo runs)"

# --- 2. CI -------------------------------------------------------------------
V=$(next_version 0.1.0)
W=$(next_version "$(echo "$V" | awk -F. '{print $1"."$2"."$3+1}')")
step "2 · CI: ./pipeline ci $APP --version $V"
say "Test, build, scan with Trivy, then publish image $APP:$V and chart $APP $V"
say "to the registry in the cluster. A published version is never overwritten."
./pipeline ci "$APP" --version "$V"

# --- 3. CD, in order ---------------------------------------------------------
for e in dev staging prod; do
  cp "$SRC/cd/$e.yaml" "cd/$APP/$e.yaml"
  if [ "$e" = dev ]; then
    step "3 · CD: ./pipeline cd $APP dev --version $V"
    say "dev has autoSync: true, so Argo CD rolls it out as soon as the change"
    say "reaches the in-stack Git server. The ApplicationSet creates $APP-dev"
    say "because cd/$APP/dev.yaml now exists."
    ./pipeline cd "$APP" dev --version "$V"
  else
    step "3 · CD: ./pipeline cd $APP $e --version $V --sync"
    say "$e only takes a version the environment before it has run, and only"
    say "while that one is healthy (Argo CD Synced and Healthy, no firing alert"
    say "for $APP). autoSync is off here: --sync stands in for the Sync click."
    ./pipeline cd "$APP" "$e" --version "$V" --sync
  fi
  serves "$V" "$(port_of "$e")"
done

# --- 4. A second version: out of order is refused ----------------------------
step "4 · CI for a second version: ./pipeline ci $APP --version $W"
./pipeline ci "$APP" --version "$W"
step "4 · Straight to prod is refused: ./pipeline cd $APP prod --version $W"
if ./pipeline cd "$APP" prod --version "$W" --sync; then
  die "prod took $W although staging never ran it"
fi
ok "refused, as it should be: promote in order"
for e in dev staging prod; do
  step "4 · ./pipeline cd $APP $e --version $W$([ "$e" = dev ] || echo ' --sync')"
  if [ "$e" = dev ]; then ./pipeline cd "$APP" dev --version "$W"; else ./pipeline cd "$APP" "$e" --version "$W" --sync; fi
  serves "$W" "$(port_of "$e")"
done

# --- 5. Rollback -------------------------------------------------------------
step "5 · Rollback: ./pipeline rollback $APP prod --sync"
say "Always allowed, no gate: back to what prod ran before ($V)."
./pipeline rollback "$APP" prod --sync
serves "$V" 8080

# --- 6. Observe --------------------------------------------------------------
step "6 · Observe hello-world next to orders-gateway"
for _ in $(seq 1 20); do curl -s -o /dev/null -H "Host: $APP.localhost" http://127.0.0.1:8080/; done
q='sum by (namespace) (http_requests_total{service="hello-world"})'
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
say "Look for yourself:"
say "  The app       http://hello-world.localhost:8080 (prod), :8082 (dev), :8083 (staging)"
say "  Argo CD       http://localhost:8081: hello-world-dev, -staging, -prod"
say "  Prometheus    http://localhost:9090: $q"
say "  Loki          Grafana (http://localhost:3000) → Explore → Loki:"
say "                {namespace=\"prod\", app=\"hello-world\"} | json"
say "  orders-gateway's SLO alerts count only orders-gateway: hello-world can't"
say "  burn its error budget or block its promotions."
step "Done: hello-world went through CI, dev → staging → prod, a refused promotion and a rollback"
say "It stays running: try ./pipeline cd hello-world dev --version $W, scale it,"
say "break it, watch it in Grafana."
