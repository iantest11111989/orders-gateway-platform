#!/usr/bin/env bash
# ./platform demo autoscale [--keep]: in a copy of prod, a fixed k6 rate
# (AUTOSCALE_RATE, default 20/s, 60% of it GET /work burning 10-50 ms of CPU
# each) pushes CPU past the HPA's 70% target; it scales from 3 to 6 pods, then
# back to 3 once k6 stops.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

# --- autoscale helpers -------------------------------------------------------

hpa_line() {
  kubectl -n "$NS" get hpa orders-gateway -o json 2>/dev/null | jq -r '
    "replicas \(.status.currentReplicas // "?") -> \(.status.desiredReplicas // "?") (min \(.spec.minReplicas), max \(.spec.maxReplicas))  CPU \(([.status.currentMetrics[]? | select(.type == "Resource") | .resource.current.averageUtilization][0]) // "?")% of requests (target \(.spec.metrics[0].resource.target.averageUtilization)%)"'
}
hpa_replicas() { kubectl -n "$NS" get hpa orders-gateway -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0; }

# Prints the HPA whenever it changes until <test> on the current replica
# count passes or the timeout runs out. Sets HPA_RESULT to "reached" or
# "timeout" and keeps the highest replica count seen in PEAK (globals, so
# call it directly, not in $(...)).
narrate_hpa() { # narrate_hpa <test: ge N | le N> <timeout s>
  local op=$1 want=$2 deadline=$(( $(date +%s) + $3 )) last='' line n
  while :; do
    line=$(hpa_line); n=$(hpa_replicas); n=${n:-0}
    [ "$n" -gt "${PEAK:-0}" ] && PEAK=$n
    if [ "$line" != "$last" ]; then printf '  %s  %s\n' "$(date +%H:%M:%S)" "$line" >&2; last=$line; fi
    if [ "$op" = ge ] && [ "$n" -ge "$want" ]; then HPA_RESULT=reached; return 0; fi
    if [ "$op" = le ] && [ "$n" -le "$want" ] && [ "$(ready_count)" -le "$want" ]; then HPA_RESULT=reached; return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || { HPA_RESULT=timeout; return 0; }
    sleep 5
  done
}

demo_autoscale() {
  local rate=${AUTOSCALE_RATE:-20} min max
  step "Demo: autoscale in a copy of prod"
  echo "  k6 sends a fixed $rate requests/s (constant arrival rate, so the load"
  echo "  is capped and doesn't grow with the cluster). 60% of it is GET /work,"
  echo "  which burns 10-50 ms of CPU on the app's single event loop: about 0.36"
  echo "  cores across 3 pods, each requesting 100m. The HPA aims for 70% of the"
  echo "  request: when the average goes over, it adds pods up to 6. When k6 stops,"
  echo "  CPU drops and after the HPA's 5-minute scale-down window it goes back to"
  echo "  3. Takes about 8 minutes."
  # Always a fresh copy, from prod's current values.
  delete_app
  create_app orders-gateway-prod v1
  wait_healthy v1 600
  min=$(kubectl -n "$NS" get hpa orders-gateway -o jsonpath='{.spec.minReplicas}')
  max=$(kubectl -n "$NS" get hpa orders-gateway -o jsonpath='{.spec.maxReplicas}')
  ok "HPA $NS/orders-gateway scales the Deployment between $min and $max pods on CPU"
  start_load "$rate"
  where_to_watch
  echo "    HPA                 ./platform shell -c 'kubectl -n $NS get hpa -w'"

  step "Scaling up under load"
  PEAK=0
  narrate_hpa ge "$max" 420
  echo "  Pods (name, node, zone, phase):" >&2; show_pods
  k6_summary
  [ "$PEAK" -gt "$min" ] || die "the HPA didn't scale up (still $PEAK pods); try a higher AUTOSCALE_RATE"
  if [ "$HPA_RESULT" = reached ]; then ok "scaled $min -> $PEAK pods under load"
  else ok "scaled $min -> $PEAK pods (not all the way to $max at $rate requests/s; AUTOSCALE_RATE raises it)"; fi

  step "Load stopped: waiting for the scale-down (the HPA waits 5 minutes before removing pods)"
  narrate_hpa le "$min" 600
  [ "$HPA_RESULT" = reached ] || die "the HPA didn't scale back to $min pods within 10 minutes (now $(hpa_replicas))"
  ok "back to $min pods: $min -> $PEAK -> $min, driven only by CPU"
  if awk -v p="${SLO_PCT:-0}" 'BEGIN { exit !(p >= 99.5) }'; then
    ok "${SLO_PCT}% of requests met the SLO (>= 99.5%) while it scaled"
  else
    warn "only ${SLO_PCT:-?}% of requests met the SLO under this load (want >= 99.5%)"
  fi
}

demo_autoscale
finish
