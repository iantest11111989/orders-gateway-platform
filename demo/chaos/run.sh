#!/usr/bin/env bash
# ./platform demo chaos [--keep]: in a copy of prod, delete a pod, then drain
# a worker (for the demo's pods): the PodDisruptionBudget and the zone spread
# keep it serving.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

# --- chaos helpers -----------------------------------------------------------

# What `kubectl drain` does per pod: an Eviction, which the API server refuses
# (429) while it would break the PodDisruptionBudget. Retries until allowed.
evict() { # evict <pod>
  local out deadline=$(( $(date +%s) + 180 )) refused=''
  while :; do
    if out=$(jq -nc --arg p "$1" --arg ns "$NS" '{apiVersion: "policy/v1", kind: "Eviction", metadata: {name: $p, namespace: $ns}}' |
        kubectl create --raw "/api/v1/namespaces/$NS/pods/$1/eviction" -f - 2>&1); then
      ok "evicted $1"; return 0
    fi
    if grep -qi 'disruption budget' <<<"$out"; then
      [ -n "$refused" ] || { warn "eviction of $1 refused: it would break the PodDisruptionBudget (maxUnavailable 1); waiting for a replacement to be ready"; refused=1; }
    else
      die "eviction of $1 failed: $out"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "the PodDisruptionBudget still refuses evicting $1 after 180s"
    sleep 3
  done
}

demo_chaos() {
  step "Demo: chaos in a copy of prod"
  echo "  First a pod is deleted: its ReplicaSet replaces it. Then a"
  echo "  worker is drained (cordoned, and the demo's pods on it evicted the way"
  echo "  kubectl drain does): the PodDisruptionBudget (maxUnavailable 1) lets"
  echo "  only one go at a time, and the pods spread across zones keep serving."
  echo "  Only the demo's pods are evicted; nothing else on the node moves."
  ensure_app orders-gateway-prod v1
  wait_healthy v1 600
  start_load
  where_to_watch
  want=$(kubectl -n "$NS" get deployment orders-gateway -o jsonpath='{.spec.replicas}')
  echo "  Pods (name, node, zone, phase):" >&2; show_pods

  step "Deleting one pod"
  victim=$(demo_pods | awk 'NR == 1 {print $1}')
  kubectl -n "$NS" delete pod "$victim" --wait=false >/dev/null
  ok "deleted $victim"
  sleep 2
  wait_ready "$want" 180
  ok "back to $want ready pods"; show_pods

  node=$(demo_pods | awk '{print $2}' | sort | uniq -c | sort -rn | awk 'NR == 1 {print $2}')
  step "Draining $node for the demo's pods"
  kubectl cordon "$node" >/dev/null; CORDONED=$node
  ok "cordoned $node: no new pods land there, from any namespace, until it's uncordoned (about a minute)"
  for p in $(demo_pods | awk -v n="$node" '$2 == n {print $1}'); do evict "$p"; done
  wait_ready "$want" 300
  left=$(demo_pods | awk -v n="$node" '$2 == n' | grep -c . || true)
  [ "$left" -eq 0 ] || die "$left demo pod(s) still on the cordoned $node"
  ok "all $want pods ready again, none on $node"; show_pods
  kubectl uncordon "$node" >/dev/null; CORDONED=''
  ok "uncordoned $node"

  sleep 10
  k6_summary
  if awk -v p="${SLO_PCT:-0}" 'BEGIN { exit !(p >= 99.5) }'; then
    ok "the service stayed up: ${SLO_PCT}% of requests met the SLO (>= 99.5%)"
  else
    die "requests failed during the chaos: only ${SLO_PCT:-?}% met the SLO (want >= 99.5%)"
  fi
}

demo_chaos
finish
