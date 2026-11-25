#!/usr/bin/env bash
# ./platform demo <name> [--keep]: narrated demos (brief, section 11).
#
#   rolling-update  v1 -> v2 in a copy of dev (3 replicas): pods replace one
#                at a time and k6 sees no errors
#   gitops-revert  a bad config commit (30% of orders fail) on a demo branch
#                that a copy of dev follows; Argo CD syncs it, then a
#                `git revert` heals it. Needs GITHUB_TOKEN (push access to the
#                repo Argo CD syncs from, e.g. your fork)
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

usage() { die "usage: ./platform demo <rolling-update|gitops-revert|canary|canary-fail|clean> [--keep]"; }
name=${1:-}; shift || true
keep=; [ "${1:-}" = --keep ] && keep=1

# --- the demo copy of prod ---------------------------------------------------

app_exists() { kubectl -n argocd get applications.argoproj.io "$APP" >/dev/null 2>&1; }

app_source() { kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.metadata.labels.demo-source}' 2>/dev/null; }

create_app() { # create_app <source app> <image tag> [helm-param=value ...]
  local src=$1 tag=$2; shift 2
  step "Creating $APP: a copy of the $src Application, image $tag"
  kubectl -n argocd get applications.argoproj.io "$src" -o json | jq --arg app "$APP" --arg ns "$NS" \
    --arg host "$HOST" --arg tag "$tag" --arg src "$src" --arg rev "${DEMO_REVISION:-}" --args '
    {apiVersion, kind,
     metadata: {name: $app, namespace: "argocd",
                labels: {"app.kubernetes.io/part-of": "orders-gateway-platform", "demo": "true", "demo-source": $src},
                # deleting the Application deletes what it created
                finalizers: ["resources-finalizer.argocd.argoproj.io"]},
     spec: (.spec
       | .destination.namespace = $ns
       | (if $rev != "" then .source.targetRevision = $rev else . end)
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
      # prod copy: the Rollout is Healthy and has a stable ReplicaSet
      ready=$(kubectl -n "$NS" get rollout orders-gateway -o jsonpath='{.status.phase}/{.status.stableRS}' 2>/dev/null | grep -E '^Healthy/.+' || true)
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
  trap 'kill "$K6_PID" 2>/dev/null || true' EXIT
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

# --- gitops-revert helpers ---------------------------------------------------

# 5xx share of POST /orders in orders-demo over the last minute, from
# Prometheus (the same metric the SLO and the canary analysis use).
error_ratio() {
  local q='sum(rate(http_requests_total{namespace="orders-demo",route="/orders",code=~"5.."}[1m])) / sum(rate(http_requests_total{namespace="orders-demo",route="/orders"}[1m]))'
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')" 2>/dev/null |
    jq -r '.data.result[0].value[1] // "0" | tonumber * 100 | floor | tostring + "%"' 2>/dev/null || echo "?"
}
# Waits until Argo CD has synced <commit> and the Deployment has rolled out,
# printing the 5xx share every 10 s; then keeps printing it for <settle> s.
narrate_git() { # narrate_git <commit> <settle s> <timeout s>
  local want=$1 settle=$2 deadline=$(( $(date +%s) + $3 )) rev synced_at=''
  kubectl -n argocd annotate applications.argoproj.io "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  while :; do
    rev=$(kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.revision}' 2>/dev/null)
    if [ -z "$synced_at" ] && [ "$rev" = "$want" ] &&
       kubectl -n "$NS" rollout status deployment/orders-gateway --timeout=1s >/dev/null 2>&1; then
      synced_at=$(date +%s)
      printf '  %s  Argo CD synced %s and the pods rolled out\n' "$(date +%H:%M:%S)" "${want:0:7}" >&2
    fi
    printf '  %s  synced %s   5xx share of POST /orders (1 min): %s\n' "$(date +%H:%M:%S)" "${rev:0:7}" "$(error_ratio)" >&2
    if [ -n "$synced_at" ] && [ $(( $(date +%s) - synced_at )) -ge "$settle" ]; then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "Argo CD didn't sync ${want:0:7} within ${3}s (it shows ${rev:0:7})"
    sleep 10
  done
}

# --- demos -------------------------------------------------------------------

demo_gitops_revert() {
  step "Demo: GitOps revert, in a copy of dev that follows a demo branch"
  echo "  A bad config commit (FAULT_ERROR_RATE 0.3: 30% of orders return 500)"
  echo "  lands on a demo branch; Argo CD syncs it and the errors show up. Then"
  echo "  \`git revert\` and Argo CD heals it. Nothing is changed by hand in the"
  echo "  cluster. Takes about 5 minutes."
  [ -n "${GITHUB_TOKEN:-}" ] || die "needs push access to the repo Argo CD syncs from: GITHUB_TOKEN=\$(gh auth token) ./platform demo gitops-revert"
  local repo base branch work push_url
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}')
  base=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.targetRevision}')
  [[ $repo == https://github.com/* ]] || die "Argo CD syncs from $repo; this demo pushes to GitHub repos over HTTPS only"
  push_url="https://x-access-token:${GITHUB_TOKEN}@${repo#https://}"
  branch="demo/gitops-revert-$(date -u +%Y%m%d-%H%M%S)"
  work=$(mktemp -d)
  DEMO_BRANCH=$branch DEMO_PUSH_URL=$push_url

  step "Creating $branch in $repo (from $base)"
  git clone -q --depth 5 --branch "$base" "$push_url" "$work"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" switch -q -c "$branch"
  git -C "$work" push -q origin "$branch"
  ok "pushed $branch"

  delete_app
  DEMO_REVISION=$branch create_app orders-dev v1 replicas=3
  wait_healthy v1 600
  start_load
  where_to_watch
  narrate_git "$(git -C "$work" rev-parse HEAD)" 30 300

  step "Committing a bad config change to $branch"
  yq -i '.config.faultErrorRate = 0.3' "$work/environments/dev/values.yaml"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" \
    commit -q -am "demo: FAULT_ERROR_RATE 0.3 in dev (30% of orders fail)"
  git -C "$work" push -q origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 60 400
  bad=$(error_ratio)

  step "Reverting it in Git"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" revert --no-edit HEAD >/dev/null
  git -C "$work" push -q origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 70 400
  good=$(error_ratio)
  k6_summary
  rm -rf "$work"

  [ "${bad%\%}" -ge 10 ] 2>/dev/null || die "the bad commit didn't show up as errors (5xx share $bad)"
  [ "${good%\%}" -le 1 ] 2>/dev/null || die "errors didn't stop after the revert (5xx share $good)"
  ok "bad commit: ${bad} of orders failed; after the revert: ${good}. Git was the only thing changed."
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
  gitops-revert) demo_gitops_revert ;;
  canary) demo_canary ;;
  canary-fail) demo_canary_fail ;;
  clean) delete_app; exit 0 ;;
  *) usage ;;
esac

if [ -n "$keep" ]; then
  ok "kept $APP running (./platform demo clean deletes it)"
  [ -z "${DEMO_BRANCH:-}" ] || ok "kept branch $DEMO_BRANCH (delete it with: git push origin --delete $DEMO_BRANCH)"
else
  delete_app
  if [ -n "${DEMO_BRANCH:-}" ]; then
    git push -q "$DEMO_PUSH_URL" --delete "$DEMO_BRANCH" && ok "deleted the demo branch $DEMO_BRANCH"
  fi
fi
