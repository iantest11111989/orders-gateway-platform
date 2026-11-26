#!/usr/bin/env bash
# scripts/persistence-check.sh record|check: does the data that matters
# survive `docker compose stop` / `start`? The E2E runs `record` before the
# stop and `check` after the platform is back.
#
#   registry     every version the env files pin is still published
#   Git server   the in-stack main is the same commit (the history ./pipeline
#                reads for promotion order)
#   Prometheus   it still has samples from before the stop
#
# record writes what it saw to .build/persistence.txt; check compares.
# Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=$ROOT/.build/persistence.txt
PROM=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query

# The in-stack main's commit, read anonymously through a port-forward.
git_main() {
  local log pf port=''
  log=$(mktemp)
  kubectl -n git port-forward svc/git :23232 >"$log" 2>&1 & pf=$!
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$log" | head -1)
    [ -n "$port" ] && break
    sleep 0.5
  done
  [ -n "$port" ] && git ls-remote "http://127.0.0.1:$port/platform.git" refs/heads/main | cut -f1
  kill "$pf" 2>/dev/null || true
  rm -f "$log"
}

# Every app:version an env file pins.
pinned() {
  local dir f
  for dir in "$ROOT"/cd/*/; do
    for f in "$dir"dev.yaml "$dir"staging.yaml "$dir"prod.yaml; do
      [ -f "$f" ] || continue
      v=$(yq '.version // ""' "$f")
      [ -z "$v" ] || echo "$(basename "$dir"):$v"
    done
  done | sort -u
}

# How many `up` series Prometheus has at a given Unix time.
up_series_at() {
  kubectl get --raw "$PROM?query=count(up)&time=$1" | jq -r '.data.result[0].value[1] // "0"'
}

case "${1:-}" in
  record)
    step "Before the stop: what must survive it"
    mkdir -p "$(dirname "$STATE")"
    rev=$(git_main); [ -n "$rev" ] || die "couldn't read the in-stack Git server's main"
    t=$(( $(date +%s) - 60 ))
    n=$(up_series_at "$t"); [ "$n" != 0 ] || die "Prometheus has no samples yet"
    { echo "main_rev=$rev"; echo "prom_time=$t"; echo "prom_up=$n"; } >"$STATE"
    # The toolbox runs as root: give .build back to the checkout's owner, or
    # ./pipeline on the host can't write there afterwards (Linux).
    chown "$(stat -c %u:%g "$ROOT")" "$(dirname "$STATE")" "$STATE" 2>/dev/null || true
    ok "in-stack main: ${rev:0:12}"
    ok "Prometheus: $n up series at $(date -u -d "@$t" +%H:%M:%S 2>/dev/null || echo "$t")"
    for p in $(pinned); do
      bash "$(dirname "$0")/registry.sh" published "${p%%:*}" "${p#*:}" || die "$p isn't published before the stop"
      ok "registry: ${p/:/ }"
    done
    ;;
  check)
    step "After the restart: is the data still there?"
    [ -f "$STATE" ] || die "no $STATE: run record before the stop"
    val() { sed -n "s/^$1=//p" "$STATE"; }
    main_rev=$(val main_rev) prom_time=$(val prom_time) prom_up=$(val prom_up)
    bad=0
    rev=$(git_main)
    if [ -n "$rev" ] && [ "$rev" = "$main_rev" ]; then ok "in-stack main unchanged: ${rev:0:12}"
    else warn "in-stack main was ${main_rev:0:12}, is now ${rev:-unreadable}"; bad=1; fi
    n=$(up_series_at "$prom_time")
    if [ "$n" != 0 ]; then ok "Prometheus still has the samples from before the stop ($n up series)"
    else warn "Prometheus has no samples from before the stop (had $prom_up)"; bad=1; fi
    for p in $(pinned); do
      if bash "$(dirname "$0")/registry.sh" published "${p%%:*}" "${p#*:}"; then ok "registry still has ${p/:/ }"
      else warn "registry lost ${p/:/ }"; bad=1; fi
    done
    [ "$bad" -eq 0 ] || die "data didn't survive docker compose stop / start"
    ;;
  *) die "usage: scripts/persistence-check.sh record|check" ;;
esac
