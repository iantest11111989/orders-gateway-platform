#!/usr/bin/env bash
# ./platform demo <name> [--keep]: narrated demos.
#
#   rolling-update  v1 -> v2 in a copy of dev (3 replicas): pods replace one
#                at a time and k6 sees no errors
#   chaos        in a copy of prod: delete a pod, then drain a worker (for the
#                demo's pods): the PodDisruptionBudget and the zone spread keep
#                it serving
#   gitops-revert  a bad config commit (30% of requests fail) on a demo branch
#                that a copy of dev follows; Argo CD syncs it, then a
#                `git revert` heals it. It pushes to the in-stack Git server
#   policy       Kyverno refuses, in namespace demo, an orders-gateway image that
#                main's app workflow didn't sign (the old staging/prod image)
#                and a :latest image; a signed image is admitted (dry run)
#   autoscale    in a copy of prod: a fixed k6 rate (AUTOSCALE_RATE, default
#                20/s, 60% of it GET /work burning 10-50 ms of CPU each) pushes
#                CPU past the HPA's 70% target, it scales from 3 to 6 pods,
#                then back to 3 once k6 stops
#   clean        delete the demo copy
#
# The demos run in namespace demo, a copy of the live prod (chaos,
# autoscale) or dev (rolling-update, gitops-revert) Argo CD Application:
# same chart, same values file and sync options. Only the name, namespace,
# Traefik entrypoint (demo, http://localhost:8084), the image under test and, for
# rolling-update, the replica count (3, so there's something to roll)
# differ, so the real environments only ever change through Git. k6 sends
# ~10 requests/s through Traefik the whole time. --keep leaves the copy
# running afterwards.
# Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

APP=orders-gateway-demo NS=demo URL=http://localhost:8084
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K6_LOG=/tmp/demo-k6.log

usage() { die "usage: ./platform demo <rolling-update|chaos|gitops-revert|autoscale|policy|clean> [--keep]"; }
name=${1:-}; shift || true
keep=; [ "${1:-}" = --keep ] && keep=1

# Runs on any exit, also Ctrl-C: stop k6, uncordon a node the chaos demo
# cordoned (so an interrupted demo never leaves a node unschedulable), and
# remove the gitops-revert clone.
K6_PID='' CORDONED='' GIT_WORK='' GIT_PF='' GIT_KEYDIR=''
cleanup() {
  [ -z "$K6_PID" ] || kill "$K6_PID" 2>/dev/null || true
  [ -z "$GIT_PF" ] || kill "$GIT_PF" 2>/dev/null || true
  [ -z "$GIT_KEYDIR" ] || rm -rf "$GIT_KEYDIR"
  if [ -n "$CORDONED" ]; then kubectl uncordon "$CORDONED" >/dev/null 2>&1 || true; fi
  [ -z "$GIT_WORK" ] || rm -rf "$GIT_WORK"
}
trap cleanup EXIT

# --- the demo copy of prod ---------------------------------------------------

app_exists() { kubectl -n argocd get applications.argoproj.io "$APP" >/dev/null 2>&1; }

app_source() { kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.metadata.labels.demo-source}' 2>/dev/null; }

create_app() { # create_app <source app> <image tag> [helm-param=value ...]
  local src=$1 tag=$2; shift 2
  # Every copy labels its pods env=demo, not the source's env, so its logs
  # (Loki's env label) and metrics never pass for the real environment's.
  set -- env=demo "$@"
  step "Creating $APP: a copy of the $src Application, image $tag"
  kubectl -n argocd get applications.argoproj.io "$src" -o json | jq --arg app "$APP" --arg ns "$NS" \
    --arg tag "$tag" --arg src "$src" --arg rev "${DEMO_REVISION:-}" --args '
    {apiVersion, kind,
     metadata: {name: $app, namespace: "argocd",
                labels: {"app.kubernetes.io/part-of": "orders-gateway-platform", "demo": "true", "demo-source": $src},
                # deleting the Application deletes what it created
                finalizers: ["resources-finalizer.argocd.argoproj.io"]},
     # One source: helm/orders-gateway from Git with the source
     # environment'"'"'s values files, whatever the source Application uses
     # (it may take its chart from the in-stack registry), and the demo
     # images v1/v2 from GHCR.
     spec: (.spec
       | ([.sources[]?, (.source // empty)] | map(select(.ref == null and .chart == null)) | first) as $git
       | ([.sources[]?, (.source // empty)] | map(select(.ref == "values")) | first) as $vals
       | .destination.namespace = $ns
       | del(.sources)
       | .source = {
           repoURL: ($git.repoURL // $vals.repoURL),
           targetRevision: (if $rev != "" then $rev else ($git.targetRevision // $vals.targetRevision) end),
           path: "helm/orders-gateway",
           helm: {
             releaseName: "app",
             valueFiles: ["../../cd/orders-gateway/values.yaml", ("../../cd/orders-gateway/" + ($src | sub("^orders-gateway-"; "")) + ".yaml")],
             parameters: ([
               {name: "ingress.entrypoint", value: "demo"},
               {name: "image.repository", value: "ghcr.io/iantest11111989/orders-gateway"},
               {name: "image.tag", value: $tag},
               {name: "image.digest", value: ""}]
               + ($ARGS.positional | map(split("=") | {name: .[0], value: (.[1:] | join("="))})))}})}' "$@" |
    kubectl apply -f - >/dev/null
  ok "Argo CD Application argocd/$APP (namespace $NS, $URL)"
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
  ok "Git-equivalent change: $APP now wants orders-gateway:$1 (Argo CD syncs it, the Deployment rolls its pods)"
}

current_tag() { kubectl -n argocd get applications.argoproj.io "$APP" -o json 2>/dev/null | jq -r '.spec.source.helm.parameters[]? | select(.name == "image.tag") | .value'; }

wait_healthy() { # wait_healthy <tag> <timeout s>
  local deadline=$(( $(date +%s) + $2 )) s ready
  while :; do
    s=$(kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
    # every Deployment replica updated and available
    ready=$(kubectl -n "$NS" get deployment app -o json 2>/dev/null |
      jq -r 'select(.status.observedGeneration >= .metadata.generation and (.status.updatedReplicas // 0) == .spec.replicas and (.status.availableReplicas // 0) == .spec.replicas and ((.status.replicas // 0) == .spec.replicas)) | "ok"' || true)
    if [ "$s" = Synced/Healthy ] && [ -n "$ready" ]; then
      ok "$APP Synced and Healthy, every pod on $1"; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "$APP not Healthy after ${2}s (app ${s:-?})"
    sleep 5
  done
}

# Waits until namespace demo is fully gone. A demo that starts while it's
# still Terminating can't create anything in it (Argo CD's sync, or the
# policy demo's pods, fail with "being terminated").
wait_ns_gone() {
  kubectl get namespace "$NS" >/dev/null 2>&1 || return 0
  kubectl wait --for=delete "namespace/$NS" --timeout=180s >/dev/null 2>&1 ||
    die "namespace $NS is still Terminating after 180 s (kubectl get namespace $NS -o yaml shows what's holding it)"
}

delete_app() {
  # A copy made before the rename was called "demo". Delete it too, but only
  # if it carries the demo=true label, so nothing else named demo is touched.
  if [ "$(kubectl -n argocd get applications.argoproj.io demo -o jsonpath='{.metadata.labels.demo}' 2>/dev/null)" = true ]; then
    step "Deleting the old demo copy (named demo, from before the rename)"
    kubectl -n argocd delete applications.argoproj.io demo --wait=true --timeout=180s >/dev/null
  fi
  app_exists || { ok "no $APP to delete"; return 0; }
  local src; src=$(app_source)
  step "Deleting $APP (the Application and everything it created)"
  kubectl -n argocd delete applications.argoproj.io "$APP" --wait=true --timeout=180s >/dev/null
  kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null
  wait_ns_gone
  ok "deleted; the real ${src:-environment} was never touched"
}

# --- load and narration ------------------------------------------------------

start_load() { # start_load [requests/s, default 10]
  local rate=${1:-10}
  step "Starting k6: ~$rate requests/s to $URL (log: $K6_LOG)"
  k6 run --quiet --summary-mode=compact \
    -e BASE_URL="$URL" -e RATE="$rate" -e DURATION=30m "$ROOT/apps/orders-gateway/k6/load.js" >"$K6_LOG" 2>&1 &
  K6_PID=$!
  sleep 15
  kill -0 "$K6_PID" 2>/dev/null || { cat "$K6_LOG"; die "k6 stopped (see above)"; }
  ok "k6 running (pid $K6_PID)"
}

where_to_watch() {
  echo "  Watch it live:"
  echo "    Argo CD             http://localhost:8081/applications/argocd/$APP"
  echo "    Grafana             http://localhost:3000 (orders-gateway dashboard, namespace $NS)"
  echo "    Terminal            ./platform shell -c 'kubectl -n $NS get pods -w'"
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
    st=$(kubectl -n "$NS" get deployment app -o json 2>/dev/null)
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
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=app -o json |
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

# --- gitops-revert helpers ---------------------------------------------------

# The in-stack Git server (default mode): Argo CD reads it at
# this URL inside the cluster; from here it's reached over SSH through a
# port-forward, with the bootstrap's key (Secret git/git-admin), as
# scripts/git-sync.sh does. Sets INSTACK_REMOTE.
IN_STACK=http://git.git.svc.cluster.local:23232/platform.git
INSTACK_REMOTE=''
instack_remote() {
  [ -z "$INSTACK_REMOTE" ] || return 0
  local log port=''
  GIT_KEYDIR=$(mktemp -d)
  kubectl -n git get secret git-admin -o jsonpath='{.data.private_key}' | base64 -d >"$GIT_KEYDIR/key" ||
    die "can't read the in-stack Git server's key (Secret git/git-admin); run ./platform up"
  chmod 600 "$GIT_KEYDIR/key"
  log="$GIT_KEYDIR/pf.log"
  : >"$log" # exists before sed reads it (the backgrounded redirect is late)
  kubectl -n git port-forward svc/git :23231 >"$log" 2>&1 &
  GIT_PF=$!
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$log" | head -1)
    [ -n "$port" ] && break
    sleep 0.5
  done
  [ -n "$port" ] || die "couldn't port-forward to the in-stack Git server: $(cat "$log")"
  export GIT_SSH_COMMAND="ssh -i $GIT_KEYDIR/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
  INSTACK_REMOTE="ssh://127.0.0.1:$port/platform.git"
}

# git against the in-stack server (instack_remote's SSH key does the auth).
gitauth() { git -c safe.directory='*' "$@"; }

# Deletes a branch on <repo> without needing the checkout to be a usable git
# repository (in a worktree checkout /work/.git points outside the mount):
# the push runs from an empty throwaway repository. DRY_RUN=1 only checks
# access (git push --dry-run) and changes nothing.
delete_branch() { # delete_branch <repo url> <branch>
  local tmp rc=0
  tmp=$(mktemp -d)
  git -C "$tmp" init -q && gitauth -C "$tmp" push -q ${DRY_RUN:+--dry-run} "$1" --delete "$2" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Deletes leftover demo branches (an interrupted run, or --keep) on the
# in-stack Git server.
clean_branches() {
  local repo b
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true)
  [ "$repo" = "$IN_STACK" ] || return 0
  instack_remote; repo=$INSTACK_REMOTE
  # Run outside /work: in a git worktree checkout, /work/.git points outside
  # the container's mount and git would refuse to start. ls-remote on a URL
  # needs no repository.
  for b in $(git -C / ls-remote --heads "$repo" 'demo/gitops-revert-*' 2>/dev/null | awk '{sub("refs/heads/", "", $2); print $2}'); do
    if delete_branch "$repo" "$b"; then ok "${DRY_RUN:+would have }deleted the leftover demo branch $b"
    else warn "couldn't delete the leftover demo branch $b"; fi
  done
}

# 5xx share of the app's requests (/work and /echo) in the demo copy over the
# last minute, from Prometheus (the same metric the availability SLO uses).
error_ratio() {
  local q='sum(rate(http_requests_total{namespace="demo",route=~"/work|/echo",status=~"5.."}[1m])) / sum(rate(http_requests_total{namespace="demo",route=~"/work|/echo"}[1m]))'
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
       kubectl -n "$NS" rollout status deployment/app --timeout=1s >/dev/null 2>&1; then
      synced_at=$(date +%s)
      printf '  %s  Argo CD synced %s and the pods rolled out\n' "$(date +%H:%M:%S)" "${want:0:7}" >&2
    fi
    printf '  %s  synced %s   5xx share of /work and /echo (1 min): %s\n' "$(date +%H:%M:%S)" "${rev:0:7}" "$(error_ratio)" >&2
    if [ -n "$synced_at" ] && [ $(( $(date +%s) - synced_at )) -ge "$settle" ]; then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "Argo CD didn't sync ${want:0:7} within ${3}s (it shows ${rev:0:7})"
    sleep 10
  done
}

# --- demos -------------------------------------------------------------------

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
  want=$(kubectl -n "$NS" get deployment app -o jsonpath='{.spec.replicas}')
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
  gen0=$(kubectl -n "$NS" get deployment app -o jsonpath='{.metadata.generation}')
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

demo_gitops_revert() {
  step "Demo: GitOps revert, in a copy of dev that follows a demo branch"
  echo "  A bad config commit (FAULT_ERROR_RATE 0.3: 30% of /work and /echo return 500)"
  echo "  lands on a demo branch; Argo CD syncs it and the errors show up. Then"
  echo "  \`git revert\` and Argo CD heals it. Nothing is changed by hand in the"
  echo "  cluster. Takes about 5 minutes."
  local repo base branch work remote
  repo=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}')
  base=$(kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.targetRevision}')
  [ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from $repo, not the in-stack Git server: run ./platform up, which points it back at this checkout"
  instack_remote; remote=$INSTACK_REMOTE
  branch="demo/gitops-revert-$(date -u +%Y%m%d-%H%M%S)"
  work=$(mktemp -d); GIT_WORK=$work
  DEMO_BRANCH=$branch DEMO_REPO=$remote

  step "Creating $branch in $repo (from $base)"
  gitauth clone -q --depth 5 --branch "$base" "$remote" "$work"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" switch -q -c "$branch"
  gitauth -C "$work" push -q origin "$branch"
  ok "pushed $branch"

  delete_app
  DEMO_REVISION=$branch create_app orders-gateway-dev v1 replicas=3
  wait_healthy v1 600
  start_load
  where_to_watch
  narrate_git "$(git -C "$work" rev-parse HEAD)" 30 300

  step "Committing a bad config change to $branch"
  yq -i '.config.faultErrorRate = 0.3' "$work/cd/orders-gateway/dev.yaml"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" \
    commit -q -am "demo: FAULT_ERROR_RATE 0.3 in dev (30% of requests fail)"
  gitauth -C "$work" push -q origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 60 400
  bad=$(error_ratio)

  step "Reverting it in Git"
  git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" revert --no-edit HEAD >/dev/null
  gitauth -C "$work" push -q origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 70 400
  good=$(error_ratio)
  k6_summary

  [ "${bad%\%}" -ge 10 ] 2>/dev/null || die "the bad commit didn't show up as errors (5xx share $bad)"
  [ "${good%\%}" -le 1 ] 2>/dev/null || die "errors didn't stop after the revert (5xx share $good)"
  ok "bad commit: ${bad} of requests failed; after the revert: ${good}. Git was the only thing changed."
}

# --- autoscale helpers -------------------------------------------------------

hpa_line() {
  kubectl -n "$NS" get hpa app -o json 2>/dev/null | jq -r '
    "replicas \(.status.currentReplicas // "?") -> \(.status.desiredReplicas // "?") (min \(.spec.minReplicas), max \(.spec.maxReplicas))  CPU \(([.status.currentMetrics[]? | select(.type == "Resource") | .resource.current.averageUtilization][0]) // "?")% of requests (target \(.spec.metrics[0].resource.target.averageUtilization)%)"'
}
hpa_replicas() { kubectl -n "$NS" get hpa app -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0; }

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
  min=$(kubectl -n "$NS" get hpa app -o jsonpath='{.spec.minReplicas}')
  max=$(kubectl -n "$NS" get hpa app -o jsonpath='{.spec.maxReplicas}')
  ok "HPA $NS/app scales the Deployment between $min and $max pods on CPU"
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

# --- policy helpers ----------------------------------------------------------

# Built before image signing; staging and prod ran it until
# 2026-11-25. Still in GHCR, never signed.
UNSIGNED_IMAGE=ghcr.io/iantest11111989/orders-gateway@sha256:09c2177caeb2c7b701c1f091fd65600065c836d4b25b930bff82cb6ec62b3476
SIGNED_IMAGE=ghcr.io/iantest11111989/orders-gateway:v1
CREATED_NS=''

# A pod that meets Pod Security "restricted" (which the app namespaces enforce, and
# which the API server checks before Kyverno), so the image is the only
# thing a policy can object to.
policy_pod() { # policy_pod <name> <image>
  jq -n --arg name "$1" --arg ns "$NS" --arg image "$2" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/name": "policy-demo"}},
    spec: {restartPolicy: "Never",
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "app", image: $image,
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "32Mi"}}}]}}'
}

# Creates the pod for real (no dry run) and expects Kyverno to refuse it.
expect_denied() { # expect_denied <name> <image> <policy>
  local out
  if out=$(policy_pod "$1" "$2" | kubectl create -f - 2>&1); then
    kubectl -n "$NS" delete pod "$1" --wait=false >/dev/null 2>&1 || true
    die "Kyverno let $2 in (is $3 in Deny? see policies/)"
  fi
  grep -q "$3" <<<"$out" || die "$2 was refused, but not by $3: $out"
  ok "refused by $3: $2"
  sed -E 's/^Error from server[^:]*: //; s/^error when creating "[^"]*": //; s/admission webhook "[^"]*" denied the request: //' <<<"$out" | fold -s -w 76 | sed 's/^/      /' >&2
}

demo_policy() {
  step "Demo: Kyverno refusing an unsigned image and a :latest image"
  echo "  In the app namespaces two policies deny: orders-gateway"
  echo "  images must carry a cosign signature from main's app workflow, and no image"
  echo "  may be :latest or untagged. Each pod below is created for real in $NS"
  echo "  (no dry run) and meets Pod Security \"restricted\", so the image is the only"
  echo "  thing wrong with it. Takes under a minute."
  echo "  Watch: ./platform shell -c 'kubectl get events -n $NS --field-selector reason=PolicyViolation -w'"
  # A namespace left Terminating by the previous demo can't take pods yet.
  if [ "$(kubectl get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" = Terminating ]; then
    ok "waiting for the previous demo's namespace $NS to finish deleting"; wait_ns_gone
  fi
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    kubectl create namespace "$NS" >/dev/null
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
    CREATED_NS=1
    ok "created namespace $NS (Pod Security restricted, like the app namespaces)"
  fi

  step "1. An orders-gateway image nobody signed"
  echo "  The image staging and prod ran until today, built before signing existed." >&2
  expect_denied policy-unsigned "$UNSIGNED_IMAGE" verify-image-signatures

  step "2. A :latest image"
  expect_denied policy-latest docker.io/library/busybox:latest disallow-latest-tag

  step "3. For contrast: the signed v1 image (server-side dry run, nothing starts)"
  local out
  if out=$(policy_pod policy-signed "$SIGNED_IMAGE" | kubectl create --dry-run=server -o name -f - 2>&1); then
    ok "admitted: $SIGNED_IMAGE carries main's signature"
  else
    die "the signed image was refused: $out"
  fi
  [ "$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=policy-demo -o name | grep -c .)" -eq 0 ] ||
    die "a policy-demo pod exists in $NS"
  ok "nothing from this demo is running in $NS"
}

case "$name" in
  rolling-update) demo_rolling_update ;;
  chaos) demo_chaos ;;
  gitops-revert) demo_gitops_revert ;;
  autoscale) demo_autoscale ;;
  policy) demo_policy ;;
  clean) delete_app; clean_branches; exit 0 ;;
  *) usage ;;
esac

if [ -n "$keep" ]; then
  if [ "$name" = policy ]; then
    if [ -n "${CREATED_NS:-}" ]; then ok "kept namespace $NS (kubectl delete namespace $NS removes it)"; fi
  else ok "kept $APP running (./platform demo clean deletes it)"; fi
  [ -z "${DEMO_BRANCH:-}" ] || ok "kept branch $DEMO_BRANCH (delete it with: git push origin --delete $DEMO_BRANCH)"
elif [ "$name" = policy ]; then
  # The policy demo creates no Application: delete only the namespace it
  # made, and leave a demo copy kept by another demo alone. Wait,
  # so the next demo doesn't find it still Terminating.
  if [ -n "${CREATED_NS:-}" ]; then
    kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null
    ok "deleted namespace $NS"
  else
    ok "left the existing $NS (from another demo) as it was"
  fi
else
  delete_app
  if [ -n "${DEMO_BRANCH:-}" ]; then
    if delete_branch "$DEMO_REPO" "$DEMO_BRANCH"; then ok "${DRY_RUN:+would have }deleted the demo branch $DEMO_BRANCH"
    else warn "couldn't delete the demo branch $DEMO_BRANCH; delete it with: git push origin --delete $DEMO_BRANCH"; fi
  fi
fi
