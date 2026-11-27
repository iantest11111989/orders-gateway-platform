#!/usr/bin/env bash
# ./platform demo alert [dev|staging|prod]: under load, switch on the
# app's own fault (POST /admin/fault, 30% of /work and /echo fail), watch the
# availability fast-burn SLO alert go pending, then firing, reach
# Alertmanager and the local receiver with its runbook link; then switch the
# fault off and watch it resolve.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

ALERT=OrdersGatewayAvailabilityFastBurn
FAULT_ON=''
# If the demo stops with the fault on, switch it off: never leave the
# environment failing on purpose.
demo_undo() { [ -z "$FAULT_ON" ] || { warn "switching the fault off (the demo stopped early)"; set_fault 0; }; }

# --- helpers -----------------------------------------------------------------

prom() { # prom <promql>: the query's JSON result, through the API server
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')"
}

# The alert's state for the environment: inactive, pending or firing.
alert_state() {
  prom "ALERTS{alertname=\"$ALERT\",namespace=\"$NS\"}" 2>/dev/null |
    jq -r '[.data.result[].metric.alertstate] | if index("firing") then "firing" elif index("pending") then "pending" else "inactive" end' 2>/dev/null || echo "?"
}

# The 5xx share the alert looks at, over its two windows.
burn() {
  local w r
  for w in 5m 1h; do
    r=$(prom "slo:orders_availability_errors:ratio_rate$w{namespace=\"$NS\"}" 2>/dev/null |
      jq -r '.data.result[0].value[1] // "0" | tonumber * 1000 | round / 10 | tostring + "%"' 2>/dev/null || echo "?")
    printf '%s %s  ' "$w" "$r"
  done
}

# set_fault <error rate>: POST /admin/fault on every demo pod, from inside
# (a port-forward to each pod; Traefik refuses /admin/* from outside). The
# fault lives in each pod's memory, so every pod is told.
set_fault() {
  local pod pf port log
  for pod in $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=orders-gateway \
      --field-selector status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
    log=$(mktemp)
    show "kubectl -n $NS port-forward pod/$pod :8080 &"
    kubectl -n "$NS" port-forward "pod/$pod" :8080 >"$log" 2>&1 & pf=$!
    port=''
    for _ in $(seq 1 30); do
      port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$log" | head -1)
      [ -n "$port" ] && break
      sleep 0.3
    done
    [ -n "$port" ] || { kill "$pf" 2>/dev/null || true; die "couldn't port-forward to $pod: $(cat "$log")"; }
    run curl -s -w '\n' -X POST -d "{\"error_rate\":$1}" "http://127.0.0.1:$port/admin/fault"
    kill "$pf" 2>/dev/null || true; rm -f "$log"
  done
}

# watch_alert <wanted state> <timeout s>: print the alert's state and the burn
# rates every 15 s, one line per change; returns 1 on timeout.
watch_alert() {
  local want=$1 deadline=$(( $(date +%s) + $2 )) st last=''
  show "kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=ALERTS{alertname=\"$ALERT\",namespace=\"$NS\"}'   # URL-encoded when sent"
  note "every 15 s until the alert is $want (up to $(( $2 / 60 )) min), with the 5xx share over the rule's two windows"
  while :; do
    st=$(alert_state)
    printf '  %s  %-9s %s\n' "$(date +%H:%M:%S)" "$st" "$(burn)"
    [ "$st" = "$want" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 15
  done
}

receiver_log() { # receiver_log <status>: the receiver's JSON lines for this alert in the environment
  kubectl -n monitoring logs deploy/alert-receiver --since=30m 2>/dev/null |
    jq -c --arg a "$ALERT" --arg ns "$NS" --arg s "$1" \
      'select(.alertname == $a and .alert_namespace == $ns and .status == $s)' 2>/dev/null || true
}

# --- the demo ----------------------------------------------------------------

demo_alert() {
  step "Demo: an SLO alert in $ENV, from a fault to the receiver and back"
  echo "  The app has a runtime fault switch: POST /admin/fault {\"error_rate\": 0.3}"
  echo "  makes 30% of /work and /echo answer 500. Traefik refuses /admin/* from"
  echo "  outside, so the demo reaches each pod from inside. The availability SLO"
  echo "  (99.5%) then burns 60x faster than allowed; the fast-burn alert fires,"
  echo "  pages the local receiver with its runbook link, and resolves once the"
  echo "  fault is off. Takes about 15 minutes, mostly waiting for the alert windows."
  echo "  This is a real alert on $ENV: it pages the receiver, and the failed"
  echo "  requests stay in $ENV's 24-hour error budget."
  wait_healthy 600
  start_load
  where_to_watch
  echo "    Alerts              http://localhost:9093 (Alertmanager), http://localhost:9090/alerts"

  step "The alert rule (stack/observability/alerts/orders-gateway-slo.yaml, a PrometheusRule)"
  show "kubectl -n monitoring get prometheusrule orders-gateway-slo -o yaml | yq '<the $ALERT rule>'"
  kubectl -n monitoring get prometheusrule orders-gateway-slo -o yaml |
    yq ".spec.groups[].rules[] | select(.alert == \"$ALERT\")" | indent
  note "it pages when more than 7.2% (14.4 x the 0.5% budget) fail over both 1 h and 5 m, for 2 minutes"
  run curl -s "http://localhost:9093/api/v2/alerts?filter=namespace=\"$NS\""
  note "Alertmanager has nothing for namespace $NS yet"

  step "1. From outside, the fault switch is refused"
  run curl -s -w '  HTTP %{http_code}\n' -X POST -d '{"error_rate":0.3}' "$URL/admin/fault"

  step "2. From inside the cluster: switch the fault on in every pod"
  set_fault 0.3; FAULT_ON=1
  sleep 5
  show "curl -s -o /dev/null -w '%{http_code} ' $URL/work   # 10 times"
  local codes=''
  for _ in $(seq 1 10); do codes+="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/work") "; done
  printf '      %s\n' "$codes"
  note "some requests now answer 500 'injected fault'; k6 keeps sending traffic"
  run kubectl -n "$NS" logs -l app.kubernetes.io/name=orders-gateway --tail=3 --prefix
  note "the app's JSON logs, as Loki stores them: level error, status 500"
  check "Grafana, orders-gateway dashboard (environment $NS), over the next few minutes" "$(dash_url orders-gateway "$NS")" \
    "/work and /echo: share failing with 5xx: jumps to about 30%" \
    "Burn rate over time: climbs past the 14.4 line; that line is the paging threshold" \
    "Availability budget left: falls fast" \
    "Firing SLO alerts: $ALERT appears as pending, then firing after 2 minutes"

  step "3. Waiting for the alert: pending, then firing after 2 minutes"
  watch_alert firing 600 || die "$ALERT didn't fire within 10 minutes"
  ok "$ALERT is firing for namespace $NS"

  step "4. Alertmanager has it, and routed it to the receiver (severity page)"
  local am
  am=$(curl -s "http://localhost:9093/api/v2/alerts?filter=namespace=\"$NS\"")
  show "curl -s 'http://localhost:9093/api/v2/alerts?filter=namespace=\"$NS\"' | jq '<name, state, severity, summary, runbook_url>'"
  jq '.[] | {alertname: .labels.alertname, state: .status.state, severity: .labels.severity,
             summary: .annotations.summary, runbook_url: .annotations.runbook_url}' <<<"$am" | indent
  local deadline=$(( $(date +%s) + 120 )) line=''
  show "kubectl -n monitoring logs deploy/alert-receiver | jq 'select(.alertname == \"$ALERT\" and .alert_namespace == \"$NS\")'"
  while [ -z "$line" ] && [ "$(date +%s)" -lt "$deadline" ]; do line=$(receiver_log firing | tail -1); [ -n "$line" ] || sleep 5; done
  if [ -n "$line" ]; then
    jq . <<<"$line" | indent
    ok "delivered: the receiver logged the page, with its runbook link"
  else
    warn "the receiver hasn't logged the page yet (Alertmanager waits group_wait, 10 s, then sends)"
  fi
  check "Alertmanager, then the receiver's log in Loki" "http://localhost:9093" \
    "Alertmanager lists $ALERT for namespace $NS, severity page, with its runbook link" \
    "$(loki_url '{namespace="monitoring", app="alert-receiver"} | json')" \
    "the receiver logged the page: that's the proof the alert was delivered, not just raised" \
    "query: {namespace=\"monitoring\", app=\"alert-receiver\"} | json"
  note "the runbook it links to (stack/observability/runbooks/$ALERT.md), first steps:"
  sed -n '1,12p' "$ROOT/stack/observability/runbooks/$ALERT.md" | indent

  step "5. Fix it: switch the fault off in every pod"
  set_fault 0; FAULT_ON=''
  ok "fault off; the 5-minute error rate falls first, then the alert resolves"

  step "6. Waiting for the alert to resolve"
  if watch_alert inactive 720; then
    ok "$ALERT resolved: no alert for namespace $NS"
    deadline=$(( $(date +%s) + 360 )); line=''
    show "kubectl -n monitoring logs deploy/alert-receiver | jq 'select(... and .status == \"resolved\")'"
    while [ -z "$line" ] && [ "$(date +%s)" -lt "$deadline" ]; do line=$(receiver_log resolved | tail -1); [ -n "$line" ] || sleep 10; done
    if [ -n "$line" ]; then jq . <<<"$line" | indent; ok "the receiver logged the resolve"
    else warn "Alertmanager hasn't sent the resolve yet (it batches every 5 minutes); it will arrive"; fi
  else
    warn "$ALERT is still active after 12 minutes; it resolves by itself once the 5-minute window is clean"
  fi
  check "Grafana, orders-gateway dashboard (environment $NS), after the fix" "$(dash_url orders-gateway "$NS")" \
    "the 5xx share drops to 0 within minutes; the 1 h burn rate falls slowly, and the alert clears once the 5-minute window is clean" \
    "the budget doesn't come back: the failures stay in its 24-hour window"
  k6_summary
  note "k6's SLO line is low on purpose here: the demo broke the service"
}

demo_alert
finish
