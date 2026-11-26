#!/usr/bin/env bash
# Shared by the demos in demo/<name>/run.sh (sourced, not run): the demo copy
# of a live Application in namespace demo, k6 load and narration, the
# in-stack Git helpers, and finish (keep or delete what the demo made).
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

APP=orders-gateway-demo NS=demo URL=http://localhost:8084
K6_LOG=/tmp/demo-k6.log

# The demo's name is its folder; --keep is the only option.
name=$(basename "$(cd "$(dirname "$0")" && pwd)")
keep=; [ "${1:-}" = --keep ] && keep=1
[ $# -eq 0 ] || [ "$1" = --keep ] || die "usage: ./platform demo $name [--keep]"

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
                labels: {"app.kubernetes.io/part-of": "platform-demo", "demo": "true", "demo-source": $src},
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
       # The demos change the copy and wait for Argo CD, so it always
       # auto-syncs, even when the source (staging, prod) does not.
       | .syncPolicy.automated = {prune: true, selfHeal: true}
       | del(.sources)
       | .source = {
           repoURL: ($git.repoURL // $vals.repoURL),
           targetRevision: (if $rev != "" then $rev else ($git.targetRevision // $vals.targetRevision) end),
           path: "helm/orders-gateway",
           helm: {
             releaseName: "orders-gateway",
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
    ready=$(kubectl -n "$NS" get deployment orders-gateway -o json 2>/dev/null |
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
  # shellcheck disable=SC2034 # read by the demos
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
       kubectl -n "$NS" rollout status deployment/orders-gateway --timeout=1s >/dev/null 2>&1; then
      synced_at=$(date +%s)
      printf '  %s  Argo CD synced %s and the pods rolled out\n' "$(date +%H:%M:%S)" "${want:0:7}" >&2
    fi
    printf '  %s  synced %s   5xx share of /work and /echo (1 min): %s\n' "$(date +%H:%M:%S)" "${rev:0:7}" "$(error_ratio)" >&2
    if [ -n "$synced_at" ] && [ $(( $(date +%s) - synced_at )) -ge "$settle" ]; then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "Argo CD didn't sync ${want:0:7} within ${3}s (it shows ${rev:0:7})"
    sleep 10
  done
}


# --- pods of the demo copy (chaos, autoscale) ----------------------------

demo_pods() { # name node phase ready, one line per demo pod
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=orders-gateway -o json |
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

# Keep what the demo made (--keep), or delete it. Every demo ends with this.
finish() {
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
}
