#!/usr/bin/env bash
# Installs Argo CD once with Helm, applies the root Application, then waits
# until every Application is Synced and Healthy (a manual-sync app: Healthy
# and synced once; this gives a new one its first sync). Called by up.sh; safe to
# re-run (Argo CD manages itself after the first install).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ARGOCD_CHART_VERSION=$(yq '.spec.sources[0].targetRevision' bootstrap/apps/templates/argocd.yaml)
# The in-stack Git server, which git-sync.sh fills with this checkout.
REPO_URL=http://git.git.svc.cluster.local:23232/platform.git
REVISION=main
APPS_TIMEOUT=${APPS_TIMEOUT:-600}

if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  step "Argo CD already installed; it manages itself from Git"
  # A repository added to its values since (configs.repositories, e.g. the
  # in-stack registry) would arrive only when Argo CD syncs itself, after the
  # apps may need it; a failed chart pull is then cached for a while. Apply
  # them now, as the chart would (Secret argocd-repo-<key>).
  yq -o json '.configs.repositories // {}' system/argocd/values.yaml | jq -c 'to_entries[]' |
    while read -r repo; do
      jq '{apiVersion: "v1", kind: "Secret",
           metadata: {name: ("argocd-repo-" + .key), namespace: "argocd",
                      labels: {"argocd.argoproj.io/secret-type": "repository"}},
           stringData: .value}' <<<"$repo" | kubectl apply -f - >/dev/null
      ok "repository $(jq -r .value.url <<<"$repo")"
    done
else
  step "Installing Argo CD (chart $ARGOCD_CHART_VERSION) with Helm, once"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    --values system/argocd/values.yaml \
    --wait --timeout 5m >/dev/null
  ok "Argo CD running"
fi

step "Applying the root Application (repo $REPO_URL @ $REVISION)"
REPO_URL="$REPO_URL" REVISION="$REVISION" yq '
  .spec.source.repoURL = strenv(REPO_URL) |
  .spec.source.targetRevision = strenv(REVISION) |
  .spec.source.helm.valuesObject.repo.url = strenv(REPO_URL) |
  .spec.source.helm.valuesObject.repo.revision = strenv(REVISION)
' bootstrap/root.yaml | kubectl apply -f - >/dev/null
ok "root applied"

step "Waiting for every Application to be Synced and Healthy (up to ${APPS_TIMEOUT}s)"
start=$(date +%s)
deadline=$(( start + APPS_TIMEOUT ))
# Seconds after the root was applied when each Application first appeared and
# first became Synced+Healthy, so slow sync waves show up in the output.
declare -A seen_at healthy_at drift_since drift_logged slow_since slow_logged first_syncs
timing() { echo "(appeared +${seen_at[$1]:-?}s, healthy +${healthy_at[$1]:-never}s)"; }
# The root app's sync waves wait only for each child's health, so an app that
# is Healthy but stays OutOfSync doesn't hold up later waves, but it does hold
# up this wait (until Argo CD's next refresh, ~3 min). Name the drifting
# resources once, so a slow `up` points at what needs an ignoreDifferences.
# An app that stays Progressing or Missing, or whose sync operation stays
# Running, for a minute is the other way to hold up `up`. Print its sync
# operation (the message names what it waits for, such as a CRD or a PostSync
# Job) and the not-ready pods in its namespace (Argo CD 3 no longer keeps
# per-resource health in the Application status). Once per app.
slow_report() {
  local ns
  warn "$1: $2 for ${3}s; sync operation, then pods not ready in its namespace:"
  kubectl -n argocd get applications.argoproj.io "$1" -o jsonpath='    operation: {.status.operationState.phase} {.status.operationState.message}{"\n"}' 2>/dev/null || true
  ns=$(kubectl -n argocd get applications.argoproj.io "$1" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)
  [ -n "$ns" ] || return 0
  kubectl -n "$ns" get pods --no-headers 2>/dev/null |
    awk -v ns="$ns" '{ split($2, r, "/"); if ($3 != "Completed" && ($3 != "Running" || r[1] != r[2])) printf "    pod %s/%s %s %s\n", ns, $1, $2, $3 }' || true
}
drift_report() {
  warn "$1: Healthy but not Synced for ${2}s; OutOfSync resources:"
  kubectl -n argocd get applications.argoproj.io "$1" -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}    {.group}/{.kind} {.namespace}/{.name}{"\n"}{end}' 2>/dev/null || true
}
# staging and prod don't sync by themselves (someone clicks Sync, or
# ./pipeline cd --sync). One that has never synced, as on a new cluster, gets
# its first sync here (again if that one failed, up to 3 times). After that, Synced isn't required of them: a change
# may be waiting for its click, so ready means Healthy and synced once.
while :; do
  # name sync health operation-phase, one line per Application; a manual app
  # that has synced before reads as Synced.
  status=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null |
    jq -r '.items[] | (.spec.syncPolicy.automated == null) as $manual
      | if $manual and .operation == null and ((.status.history // []) | length) == 0
           and (.status.operationState == null or (.status.operationState.phase | IN("Failed", "Error")))
        then "SYNC \(.metadata.name)" else empty end,
        "\(.metadata.name) \(if $manual and .status.operationState.phase == "Succeeded" then "Synced" else (.status.sync.status // "") end) \(.status.health.status // "") \(.status.operationState.phase // "")"' || true)
  while read -r name; do
    [ -n "$name" ] || continue
    first_syncs[$name]=$(( ${first_syncs[$name]:-0} + 1 ))
    if [ "${first_syncs[$name]}" -gt 3 ]; then
      die "$name: its first sync failed 3 times: $(kubectl -n argocd get applications.argoproj.io "$name" -o jsonpath='{.status.operationState.message}' 2>/dev/null)"
    fi
    sync_app "$name" bootstrap && ok "$name: first sync started (staging and prod sync on demand)"
  done < <(sed -n 's/^SYNC //p' <<<"$status")
  status=$(grep -v '^SYNC ' <<<"$status" || true)
  now=$(( $(date +%s) - start ))
  while read -r name sync health phase; do
    [ -n "$name" ] || continue
    [ -n "${seen_at[$name]:-}" ] || seen_at[$name]=$now
    if [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ -z "${healthy_at[$name]:-}" ]; then healthy_at[$name]=$now; fi
    # Skip apps still in a sync (root works through its waves this way).
    if [ "$health" = Healthy ] && [ "$sync" != Synced ] && [ "${phase:-}" != Running ]; then
      [ -n "${drift_since[$name]:-}" ] || drift_since[$name]=$now
      if [ -z "${drift_logged[$name]:-}" ] && [ $(( now - drift_since[$name] )) -ge 30 ]; then
        drift_logged[$name]=1
        drift_report "$name" $(( now - drift_since[$name] ))
      fi
    else
      unset 'drift_since[$name]'
    fi
    # A sync operation still Running with healthy resources is a hook (e.g.
    # a PostSync Job) the app waits for; it counts as slow too.
    if [ "$health" = Progressing ] || [ "$health" = Missing ] || [ "${phase:-}" = Running ]; then
      [ -n "${slow_since[$name]:-}" ] || slow_since[$name]=$now
      if [ -z "${slow_logged[$name]:-}" ] && [ $(( now - slow_since[$name] )) -ge 60 ]; then
        slow_logged[$name]=1
        slow_report "$name" "$health, sync ${phase:-idle}" $(( now - slow_since[$name] ))
      fi
    else
      unset 'slow_since[$name]'
    fi
  done <<<"$status"
  total=$(grep -c . <<<"$status" || true)
  ready=$(awk '$2 == "Synced" && $3 == "Healthy"' <<<"$status" | grep -c . || true)
  if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
    while read -r name _ _; do ok "$name: Synced, Healthy $(timing "$name")"; done <<<"$status"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    while read -r name sync health _; do
      if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then ok "$name: Synced, Healthy $(timing "$name")"; else fail "$name: ${sync:-Unknown}, ${health:-Unknown} $(timing "$name")"; fi
    done <<<"$status"
    die "not every Application became Synced and Healthy in ${APPS_TIMEOUT}s. Inspect with: ./platform kubectl -n argocd get applications"
  fi
  sleep 5
done
