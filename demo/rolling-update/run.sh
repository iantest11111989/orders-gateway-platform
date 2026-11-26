#!/usr/bin/env bash
# ./platform demo rolling-update [--keep]: v1 -> v2 in a copy of dev (3
# replicas): pods replace one at a time and k6 sees no errors.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

demo_rolling_update() {
  step "Demo: rolling update v1 -> v2 in a copy of dev"
  echo "  The Deployment replaces its 3 pods one at a time (maxSurge 1,"
  echo "  maxUnavailable 0): a new pod must pass its readiness probe before an old"
  echo "  one drains (5 s) and stops. k6 keeps sending traffic. Takes about 1 minute."
  ensure_app orders-gateway-dev v1 replicas=3
  wait_healthy v1 600
  start_load
  where_to_watch
  step "Rolling out v2"
  gen0=$(kubectl -n "$NS" get deployment orders-gateway -o jsonpath='{.metadata.generation}')
  set_image v2
  result=$(narrate_rolling "$gen0" 300)
  sleep 15 # let k6 run against the new pods for a moment before stopping it
  k6_summary
  [ "$result" = finished ] || die "the rolling update didn't finish (result: $result)"
  if awk -v p="${SLO_PCT:-0}" 'BEGIN { exit !(p >= 99.5) }'; then
    ok "every pod replaced with v2; ${SLO_PCT}% of requests met the SLO (>= 99.5%)"
  else
    die "requests failed during the rolling update: only ${SLO_PCT:-?}% met the SLO (want >= 99.5%)"
  fi
}

demo_rolling_update
finish
