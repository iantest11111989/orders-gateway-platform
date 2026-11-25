#!/usr/bin/env bash
# ./platform demo <name> [--keep]: narrated demos (brief, section 11).
#
#   rolling-update  v1 -> v2 in a copy of dev (3 replicas): pods replace one
#                at a time and k6 sees no errors
#   chaos        in a copy of prod: delete a pod, then drain a worker (for the
#                demo's pods): the PodDisruptionBudget and the zone spread keep
#                it serving
#   canary       v1 -> v2 through the prod canary: 10% -> 25% -> 50% -> 100%,
#                with the SLO analysis passing at every step
#   canary-fail  v2 -> v2-bad: the analysis fails and Rollouts rolls back
#   clean        delete the demo copy
#
# The demos run in orders-demo, a copy of the live orders-prod (canary demos)
# or orders-dev (rolling-update) Argo CD Application: same chart, same values
# file, same ignoreDifferences and sync options. Only the name, namespace,
# hostname (orders-demo.localtest.me), the image under test and, for
# rolling-update, the replica count (3, so there's something to roll)
# differ. The real environments only ever change through Git, and reviewers
# can't push to this repo (decision 0020). k6 sends ~10 requests/s through
# the gateway the whole time, so the analysis has traffic to judge. --keep
# leaves the copy running afterwards.
# Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

APP=orders-demo NS=orders-demo HOST=orders-demo.localtest.me
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K6_LOG=/tmp/orders-demo-k6.log

usage() { die "usage: ./platform demo <rolling-update|chaos|canary|canary-fail|clean> [--keep]"; }
name=${1:-}; shift || true
keep=; [ "${1:-}" = --keep ] && keep=1

# Runs on any exit, also Ctrl-C: stop k6 and uncordon a node the chaos demo
# cordoned, so an interrupted demo never leaves a node unschedulable.
K6_PID='' CORDONED=''
cleanup() {
  [ -z "$K6_PID" ] || kill "$K6_PID" 2>/dev/null || true
  if [ -n "$CORDONED" ]; then kubectl uncordon "$CORDONED" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# --- the demo copy of prod ---------------------------------------------------

app_exists() { kubectl -n argocd get applications.argoproj.io "$APP" >/dev/null 2>&1; }

app_source() { kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.metadata.labels.demo-source}' 2>/dev/null; }

create_app() { # create_app <source app> <image tag> [helm-param=value ...]
  local src=$1 tag=$2; shift 2
  step "Creating $APP: a copy of the $src Application, image $tag"
  kubectl -n argocd get applications.argoproj.io "$src" -o json | jq --arg app "$APP" --arg ns "$NS" \
    --arg host "$HOST" --arg tag "$tag" --arg src "$src" --args '
    {apiVersion, kind,
     metadata: {name: $app, namespace: "argocd",
                labels: {"app.kubernetes.io/part-of": "orders-gateway-platform", "demo": "true", "demo-source": $src},
                # deleting the Application deletes what it created
                finalizers: ["resources-finalizer.argocd.argoproj.io"]},
     spec: (.spec
       | .destination.namespace = $ns
       | .source.helm.parameters = ([
           {name: "route.hostname", value: $host},
           {name: "image.tag", value: $tag},
           {name: "image.digest", value: ""}]
           + ($ARGS.positional | map(split("=") | {name: .[0], value: (.[1:] | join("="))}))))}' "$@" |
    kubectl apply -f - >/dev/null
  ok "Argo CD Application argocd/$APP (namespace $NS, https://$HOST)"
}

# ensure_app <source app> <tag> [params...]: reuse the copy if it already
# comes from <source> and runs <tag>, otherwise make a fresh one.
ensure_app() {
  if app_exists && [ "$(app_source)" = "$1" ] && [ "$(current_tag)" = "$2" ]; then ok "$APP already a copy of $1 on $2"
  else delete_app; create_app "$@"; fi
}

set_image() { # set_image <tag>
  # Rewrites the image.tag parameter by name, whatever its position.
  kubectl -n argocd get applications.argoproj.io "$APP" -o json |
    jq --arg tag "$1" '.spec.source.helm.parameters |= map(if .name == "image.tag" then .value = $tag else . end)
                       | {spec: {source: {helm: {parameters: .spec.source.helm.parameters}}}}' |
    kubectl -n argocd patch applications.argoproj.io "$APP" --type merge --patch-file /dev/stdin >/dev/null
  local how="the Deployment rolls its pods"
  kubectl -n "$NS" get rollout orders-gateway >/dev/null 2>&1 && how="Rollouts starts a canary"
  ok "Git-equivalent change: $APP now wants orders-gateway:$1 (Argo CD syncs it, $how)"
}

current_tag() { kubectl -n argocd get applications.argoproj.io "$APP" -o json 2>/dev/null | jq -r '.spec.source.helm.parameters[]? | select(.name == "image.tag") | .value'; }

wait_healthy() { # wait_healthy <tag> <timeout s>
  local deadline=$(( $(date +%s) + $2 )) s ready
  while :; do
    s=$(kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
    if kubectl -n "$NS" get rollout orders-gateway >/dev/null 2>&1; then
      # prod copy: the Rollout is Healthy with a stable ReplicaSet, and has
      # scaled the Deployment it references (workloadRef) down to no pods
      ready=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.phase}/{.status.stableRS}' 2>/dev/null | grep -E '^Healthy/.+' || true)
      [ "$(kubectl -n "$NS" get deployment orders-gateway -o jsonpath='{.status.replicas}' 2>/dev/null)" -gt 0 ] 2>/dev/null && ready=''
    else
      # dev copy: every Deployment replica updated and available
      ready=$(kubectl -n "$NS" get deployment orders-gateway -o json 2>/dev/null |
        jq -r 'select(.status.observedGeneration >= .metadata.generation and (.status.updatedReplicas // 0) == .spec.replicas and (.status.availableReplicas // 0) == .spec.replicas and ((.status.replicas // 0) == .spec.replicas)) | "ok"' || true)
    fi
    if [ "$s" = Synced/Healthy ] && [ -n "$ready" ]; then
      ok "$APP Synced and Healthy, every pod on $1"; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "$APP not Healthy after ${2}s (app ${s:-?})"
    sleep 5
  done
}

delete_app() {
  app_exists || { ok "no $APP to delete"; return 0; }
  local src; src=$(app_source)
  step "Deleting $APP (the Application and everything it created)"
  kubectl -n argocd delete applications.argoproj.io "$APP" --wait=true --timeout=180s >/dev/null
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null
  ok "deleted; the real ${src:-environment} was never touched"
}

# --- load and narration ------------------------------------------------------

start_load() {
  step "Starting k6: ~10 requests/s to https://$HOST (log: $K6_LOG)"
  # The demo CA isn't in k6's trust store; this is the demo's own hostname.
  k6 run --quiet --insecure-skip-tls-verify --summary-mode=compact \
    -e BASE_URL="https://$HOST" -e RATE=10 -e DURATION=30m "$ROOT/app/k6/load.js" >"$K6_LOG" 2>&1 &
  K6_PID=$!
  sleep 15
  kill -0 "$K6_PID" 2>/dev/null || { cat "$K6_LOG"; die "k6 stopped (see above)"; }
  ok "k6 running (pid $K6_PID)"
}

where_to_watch() {
  echo "  Watch it live:"
  kubectl -n "$NS" get rollout orders-gateway >/dev/null 2>&1 &&
    echo "    Rollouts dashboard  https://rollouts.localtest.me/rollouts/$NS"
  echo "    Argo CD             https://argocd.localtest.me/applications/argocd/$APP"
  echo "    Grafana             https://grafana.localtest.me (orders-gateway dashboard, namespace $NS)"
  if kubectl -n "$NS" get rollout orders-gateway >/dev/null 2>&1; then
    echo "    Terminal            ./platform shell -c 'kubectl argo rollouts get rollout orders-gateway -n $NS --watch'"
  else
    echo "    Terminal            ./platform shell -c 'kubectl -n $NS get pods -w'"
  fi
}

# Prints one line whenever the step, weights, analysis or phase change, until
# the rollout ends (Healthy or Degraded) or the timeout passes. Echoes the
# final phase.
narrate() { # narrate <timeout s>
  local deadline=$(( $(date +%s) + $1 )) last='' line phase step weights runs started='' steps
  steps=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.spec.strategy.canary.steps}' 2>/dev/null | jq length 2>/dev/null || echo '?')
  while :; do
    phase=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.phase}' 2>/dev/null || true)
    step=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)
    weights=$(kubectl -n "$NS" get httproute orders-gateway \
      -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.weight}{"/"}{end}' 2>/dev/null | sed 's|/$||')
    runs=$(kubectl -n "$NS" get analysisruns --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null || true)
    line="phase=${phase:-?}  step=${step:-?}/${steps}  stable/canary weight=${weights:-?}  analysis runs: ${runs:-none}"
    if [ "$line" != "$last" ]; then printf '  %s  %s\n' "$(date +%H:%M:%S)" "$line" >&2; last=$line; fi
    # Right after the image change the Rollout can still read Healthy from
    # the previous version: only accept Healthy once the canary has started.
    case "$phase" in
      Progressing|Paused) started=1 ;;
      Degraded) echo Degraded; return 0 ;;
      Healthy) [ -n "$started" ] && { echo Healthy; return 0; } ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "timeout"; return 0; fi
    sleep 5
  done
}

# Stops k6 (SIGINT makes it print its end-of-test summary) and reports the
# SLO rate it measured from the client side.
k6_summary() {
  local slo
  kill -INT "$K6_PID" 2>/dev/null || true
  wait "$K6_PID" 2>/dev/null || true
  # e.g. "orders_slo_good......: 99.91% 4021 out of 4025"
  slo=$(grep -m1 -E 'orders_slo_good\.+:' "$K6_LOG" | sed -E 's/^[^:]*:[[:space:]]*//' || true)
  ok "k6 sent traffic the whole time; requests meeting the SLO: ${slo:-see $K6_LOG}"
  SLO_PCT=$(sed -E 's/%.*//' <<<"${slo:-}")
}

# One line per change in the Deployment's rollout: new ReplicaSet ready, old
# ReplicaSet still serving, until every replica runs the new version.
narrate_rolling() { # narrate_rolling <generation before the change> <timeout s>
  local gen0=$1 deadline=$(( $(date +%s) + $2 )) last='' line st
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

# --- chaos helpers -----------------------------------------------------------

demo_pods() { # name node phase ready, one line per demo pod
  # With a Rollout, only its pods (they carry rollouts-pod-template-hash), not
  # a pod of the referenced Deployment that is still scaling down.
  local sel=app.kubernetes.io/name=orders-gateway
  kubectl -n "$NS" get rollout orders-gateway >/dev/null 2>&1 && sel="$sel,rollouts-pod-template-hash"
  kubectl -n "$NS" get pods -l "$sel" -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null) |
      "\(.metadata.name) \(.spec.nodeName // "-") \(.status.phase) \(([.status.conditions[]? | select(.type == "Ready") | .status][0]) // "False")"'
}
ready_count() { demo_pods | awk '$4 == "True"' | grep -c . || true; }
show_pods() {
  demo_pods | while read -r name node phase ready; do
    zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo -)
    printf '    %-40s %-14s %-7s %s ready=%s\n' "$name" "$node" "$zone" "$phase" "$ready" >&2
  done
}
wait_ready() { # wait_ready <n> <timeout s>
  local deadline=$(( $(date +%s) + $2 )) last='' n
  while :; do
    n=$(ready_count)
    [ "$n" != "$last" ] && { printf '  %s  ready pods: %s\n' "$(date +%H:%M:%S)" "$n" >&2; last=$n; }
    [ "$n" -ge "$1" ] && return 0
    [ "$(date +%s)" -lt "$deadline" ] || die "only $n of $1 pods ready after ${2}s"
    sleep 2
  done
}
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

# --- demos -------------------------------------------------------------------

demo_chaos() {
  step "Demo: chaos in a copy of prod"
  echo "  First a pod is deleted: the Rollout's ReplicaSet replaces it. Then a"
  echo "  worker is drained (cordoned, and the demo's pods on it evicted the way"
  echo "  kubectl drain does): the PodDisruptionBudget (maxUnavailable 1) lets"
  echo "  only one go at a time, and the pods spread across zones keep serving."
  echo "  Only the demo's pods are evicted; nothing else on the node moves."
  ensure_app orders-prod v1
  wait_healthy v1 600
  start_load
  where_to_watch
  want=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.spec.replicas}')
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
  ok "cordoned $node (no new pods land there)"
  for p in $(demo_pods | awk -v n="$node" '$2 == n {print $1}'); do evict "$p"; done
  wait_ready "$want" 300
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


demo_rolling_update() {
  step "Demo: rolling update v1 -> v2 in a copy of dev"
  echo "  The Deployment replaces its 3 pods one at a time (maxSurge 1,"
  echo "  maxUnavailable 0): a new pod must pass its readiness probe before an old"
  echo "  one drains (5 s) and stops. k6 keeps sending traffic. Takes about 1 minute."
  ensure_app orders-dev v1 replicas=3
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

demo_canary() {
  step "Demo: canary v1 -> v2 in a copy of prod"
  echo "  Rollouts moves traffic 10% -> 25% -> 50% -> 100% through the HTTPRoute,"
  echo "  and after each step asks Prometheus whether the canary meets the SLO"
  echo "  (5xx ratio <= 0.5%, p99 < 300 ms). Takes about 10 minutes."
  ensure_app orders-prod v1
  wait_healthy v1 600
  start_load
  where_to_watch
  step "Promoting v2"
  set_image v2
  result=$(narrate 1200)
  k6_summary
  case "$result" in
    Healthy) ok "v2 promoted: every analysis passed, 100% of traffic on v2" ;;
    *) die "canary did not finish Healthy (result: $result)" ;;
  esac
}

demo_canary_fail() {
  step "Demo: canary-fail v2 -> v2-bad in a copy of prod"
  echo "  v2-bad injects errors and latency. The first analysis fails the SLO,"
  echo "  Rollouts aborts, and all traffic goes back to v2. Takes about 3 minutes."
  ensure_app orders-prod v2
  wait_healthy v2 600
  start_load
  where_to_watch
  step "Promoting v2-bad"
  set_image v2-bad
  result=$(narrate 900)
  k6_summary
  weights=$(kubectl -n "$NS" get httproute orders-gateway \
    -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}')
  case "$result" in
    Degraded)
      ok "analysis failed and Rollouts aborted: $(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.message}')"
      ok "traffic is back on the stable version: $weights" ;;
    *) die "expected the canary to abort (result: $result)" ;;
  esac
}

case "$name" in
  rolling-update) demo_rolling_update ;;
  chaos) demo_chaos ;;
  canary) demo_canary ;;
  canary-fail) demo_canary_fail ;;
  clean) delete_app; exit 0 ;;
  *) usage ;;
esac

if [ -n "$keep" ]; then
  ok "kept $APP running (./platform demo clean deletes it)"
else
  delete_app
fi
