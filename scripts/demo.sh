#!/usr/bin/env bash
# ./platform demo <name> [--keep]: narrated demos (brief, section 11).
#
#   canary       v1 -> v2 through the prod canary: 10% -> 25% -> 50% -> 100%,
#                with the SLO analysis passing at every step
#   canary-fail  v2 -> v2-bad: the analysis fails and Rollouts rolls back
#   clean        delete the demo copy
#
# The demos run in orders-demo, a copy of prod made from the live orders-prod
# Argo CD Application: same chart, same environments/prod/values.yaml, same
# ignoreDifferences and sync options. Only the name, namespace, hostname
# (orders-demo.localtest.me) and the image under test differ. Real prod only
# ever changes through Git, and reviewers can't push to this repo (decision
# 0020). k6 sends ~10 requests/s through the gateway the whole time, so the
# analysis has traffic to judge. --keep leaves the copy running afterwards.
# Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

APP=orders-demo NS=orders-demo HOST=orders-demo.localtest.me
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K6_LOG=/tmp/orders-demo-k6.log

usage() { die "usage: ./platform demo <canary|canary-fail|clean> [--keep]"; }
name=${1:-}; shift || true
keep=; [ "${1:-}" = --keep ] && keep=1

# --- the demo copy of prod ---------------------------------------------------

app_exists() { kubectl -n argocd get applications.argoproj.io "$APP" >/dev/null 2>&1; }

create_app() { # create_app <image tag>
  step "Creating $APP: a copy of the orders-prod Application, image $1"
  kubectl -n argocd get applications.argoproj.io orders-prod -o json | jq --arg app "$APP" --arg ns "$NS" \
    --arg host "$HOST" --arg tag "$1" '
    {apiVersion, kind,
     metadata: {name: $app, namespace: "argocd",
                labels: {"app.kubernetes.io/part-of": "orders-gateway-platform", "demo": "true"},
                # deleting the Application deletes what it created
                finalizers: ["resources-finalizer.argocd.argoproj.io"]},
     spec: (.spec
       | .destination.namespace = $ns
       | .source.helm.parameters = [
           {name: "route.hostname", value: $host},
           {name: "image.tag", value: $tag},
           {name: "image.digest", value: ""}])}' |
    kubectl apply -f - >/dev/null
  ok "Argo CD Application argocd/$APP (namespace $NS, https://$HOST)"
}

set_image() { # set_image <tag>
  kubectl -n argocd patch applications.argoproj.io "$APP" --type json -p "$(jq -nc --arg tag "$1" '
    [{op: "replace", path: "/spec/source/helm/parameters/1", value: {name: "image.tag", value: $tag}}]')" >/dev/null
  ok "Git-equivalent change: $APP now wants orders-gateway:$1 (Argo CD syncs it, Rollouts starts a canary)"
}

current_tag() { kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.spec.source.helm.parameters[1].value}' 2>/dev/null; }

wait_healthy() { # wait_healthy <tag> <timeout s>
  local deadline=$(( $(date +%s) + $2 )) s phase img
  while :; do
    s=$(kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
    phase=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.phase}' 2>/dev/null || true)
    img=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.stableRS}' 2>/dev/null || true)
    if [ "$s" = Synced/Healthy ] && [ "$phase" = Healthy ] && [ -n "$img" ]; then
      ok "$APP Synced and Healthy, every pod on $1"; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "$APP not Healthy after ${2}s (app $s, rollout ${phase:-none})"
    sleep 5
  done
}

delete_app() {
  app_exists || { ok "no $APP to delete"; return 0; }
  step "Deleting $APP (the Application and everything it created)"
  kubectl -n argocd delete applications.argoproj.io "$APP" --wait=true --timeout=180s >/dev/null
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null
  ok "deleted; real prod (orders-prod) was never touched"
}

# --- load and narration ------------------------------------------------------

start_load() {
  step "Starting k6: ~10 requests/s to https://$HOST (log: $K6_LOG)"
  # The demo CA isn't in k6's trust store; this is the demo's own hostname.
  k6 run --quiet --insecure-skip-tls-verify --summary-mode=compact \
    -e BASE_URL="https://$HOST" -e RATE=10 -e DURATION=30m "$ROOT/app/k6/load.js" >"$K6_LOG" 2>&1 &
  K6_PID=$!
  trap 'kill "$K6_PID" 2>/dev/null || true' EXIT
  sleep 15
  kill -0 "$K6_PID" 2>/dev/null || { cat "$K6_LOG"; die "k6 stopped (see above)"; }
  ok "k6 running (pid $K6_PID)"
}

where_to_watch() {
  echo "  Watch it live:"
  echo "    Rollouts dashboard  https://rollouts.localtest.me/rollouts/$NS"
  echo "    Argo CD             https://argocd.localtest.me/applications/argocd/$APP"
  echo "    Grafana             https://grafana.localtest.me (orders-gateway dashboard, namespace $NS)"
  echo "    Terminal            ./platform shell -c 'kubectl argo rollouts get rollout orders-gateway -n $NS --watch'"
}

# Prints one line whenever the step, weights, analysis or phase change, until
# the rollout ends (Healthy or Degraded) or the timeout passes. Echoes the
# final phase.
narrate() { # narrate <timeout s>
  local deadline=$(( $(date +%s) + $1 )) last='' line phase step weights runs started=''
  while :; do
    phase=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.phase}' 2>/dev/null || true)
    step=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)
    weights=$(kubectl -n "$NS" get httproute orders-gateway \
      -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.weight}{"/"}{end}' 2>/dev/null | sed 's|/$||')
    runs=$(kubectl -n "$NS" get analysisruns --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null || true)
    line="phase=${phase:-?}  step=${step:-?}/6  stable/canary weight=${weights:-?}  analysis runs: ${runs:-none}"
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
}

# --- demos -------------------------------------------------------------------

demo_canary() {
  step "Demo: canary v1 -> v2 in a copy of prod"
  echo "  Rollouts moves traffic 10% -> 25% -> 50% -> 100% through the HTTPRoute,"
  echo "  and after each step asks Prometheus whether the canary meets the SLO"
  echo "  (5xx ratio <= 0.5%, p99 < 300 ms). Takes about 10 minutes."
  if app_exists && [ "$(current_tag)" = v1 ]; then ok "$APP already on v1"
  else delete_app; create_app v1; fi
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
  if app_exists && [ "$(current_tag)" = v2 ]; then ok "$APP already on v2"
  else delete_app; create_app v2; fi
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
