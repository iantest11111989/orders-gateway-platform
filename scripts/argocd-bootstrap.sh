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
deadline=$(( $(date +%s) + APPS_TIMEOUT ))
polls=0
while :; do
  # name sync health, one line per Application
  status=$(kubectl -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null || true)
  total=$(grep -c . <<<"$status" || true)
  ready=$(awk '$2 == "Synced" && $3 == "Healthy"' <<<"$status" | grep -c . || true)
  if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
    while read -r name _ _; do ok "$name: Synced, Healthy"; done <<<"$status"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    while read -r name sync health; do
      if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then ok "$name: Synced, Healthy"; else fail "$name: ${sync:-Unknown}, ${health:-Unknown}"; fi
    done <<<"$status"
    die "not every Application became Synced and Healthy in ${APPS_TIMEOUT}s. Inspect with: ./platform kubectl -n argocd get applications"
  fi
  # Argo CD re-checks health only every timeout.reconciliation (3 min), so an
  # Application that synced but was still Progressing (CRDs not yet
  # Established, pods starting) can look stuck for minutes and hold back the
  # next sync wave. Every 30 s, ask Argo CD to refresh those.
  polls=$((polls + 1))
  if [ $((polls % 6)) -eq 0 ]; then
    awk '$2 == "Synced" && $3 == "Progressing" {print $1}' <<<"$status" |
      while read -r app; do
        kubectl -n argocd annotate applications.argoproj.io "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
      done
  fi
  sleep 5
done
