#!/usr/bin/env bash
# Installs Argo CD once with Helm, applies the root Application, then waits
# until every Application is Synced and Healthy. Called by up.sh; safe to
# re-run (Argo CD manages itself after the first install).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ARGOCD_CHART_VERSION=$(yq '.spec.sources[0].targetRevision' gitops/apps/templates/argocd.yaml)
REPO_URL=${REPO_URL:-https://github.com/iantest11111989/orders-gateway-platform.git}
REVISION=${REVISION:-main}
APPS_TIMEOUT=${APPS_TIMEOUT:-600}

if kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  step "Argo CD already installed; it manages itself from Git"
else
  step "Installing Argo CD (chart $ARGOCD_CHART_VERSION) with Helm, once"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    --values gitops/values/argocd.yaml \
    --wait --timeout 5m >/dev/null
  ok "Argo CD running"
fi

step "Applying the root Application (repo $REPO_URL @ $REVISION)"
REPO_URL="$REPO_URL" REVISION="$REVISION" yq '
  .spec.source.repoURL = strenv(REPO_URL) |
  .spec.source.targetRevision = strenv(REVISION) |
  .spec.source.helm.valuesObject.repo.url = strenv(REPO_URL) |
  .spec.source.helm.valuesObject.repo.revision = strenv(REVISION)
' gitops/root.yaml | kubectl apply -f - >/dev/null
ok "root applied"

step "Waiting for every Application to be Synced and Healthy (up to ${APPS_TIMEOUT}s)"
start=$(date +%s)
deadline=$(( start + APPS_TIMEOUT ))
# Seconds after the root was applied when each Application first appeared and
# first became Synced+Healthy, so slow sync waves show up in the output.
declare -A seen_at healthy_at drift_since drift_logged
timing() { echo "(appeared +${seen_at[$1]:-?}s, healthy +${healthy_at[$1]:-never}s)"; }
# The root app's sync waves wait only for each child's health, so an app that
# is Healthy but stays OutOfSync doesn't hold up later waves, but it does hold
# up this wait (until Argo CD's next refresh, ~3 min). Name the drifting
# resources once, so a slow `up` points at what needs an ignoreDifferences.
drift_report() {
  warn "$1: Healthy but not Synced for ${2}s; OutOfSync resources:"
  kubectl -n argocd get applications.argoproj.io "$1" -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}    {.group}/{.kind} {.namespace}/{.name}{"\n"}{end}' 2>/dev/null || true
}
while :; do
  # name sync health operation-phase, one line per Application
  status=$(kubectl -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}{end}' 2>/dev/null || true)
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
