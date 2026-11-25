#!/usr/bin/env bash
# Tests the Application health customization in argocd-cm (the root's sync
# wave gate, gitops/values/argocd.yaml) against fixture Applications in
# tests/argocd/, with the cluster's live argocd-cm:
#   argocd admin settings resource-overrides health <app> --argocd-cm-path …
# Each fixture's expected status is in the case list below. Runs in the
# toolbox after `up` (CI: platform job).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
dir="$(dirname "$0")/../tests/argocd"
cm=$(mktemp)
trap 'rm -f "$cm"' EXIT
kubectl -n argocd get configmap argocd-cm -o yaml >"$cm"

step "Argo CD Application health (the sync-wave gate) against fixtures"
failed=0
while read -r fixture want; do
  got=$(argocd admin settings resource-overrides health "$dir/$fixture" --argocd-cm-path "$cm" 2>/dev/null |
    awk '/^STATUS:/ {print $2}')
  if [ "$got" = "$want" ]; then ok "$fixture: $got"
  else fail "$fixture: got '${got:-nothing}', want $want"; failed=1; fi
done <<'CASES'
app-new-child.yaml Progressing
app-synced-no-history.yaml Healthy
app-synced.yaml Healthy
app-degraded.yaml Degraded
CASES
[ "$failed" -eq 0 ] || die "Application health customization doesn't behave as the sync waves need"
