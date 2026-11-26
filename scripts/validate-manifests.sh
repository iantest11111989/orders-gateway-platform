#!/usr/bin/env bash
# Renders everything Argo CD applies, so CI can validate it in seconds,
# without a cluster (CI · platform, "Validate manifests"):
#   - helm lint, then helm template of charts/orders-gateway for dev, staging
#     and prod with their values files (and prod with the demo's canary on)
#   - the app-of-apps chart (gitops/apps)
#   - every folder in gitops/manifests (Kustomize where it has a
#     kustomization.yaml, the YAML files as they are otherwise)
# into out/rendered/*.yaml. kubeconform then checks them against the
# Kubernetes and CRD schemas, and kyverno against our policies. Runs in the
# toolbox: ./platform shell scripts/validate-manifests.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=out/rendered
rm -rf "$OUT"; mkdir -p "$OUT"

step "Helm: lint and render the app chart per environment"
for env in dev staging prod; do
  helm lint charts/orders-gateway -f "environments/$env/values.yaml" --namespace "$env" --quiet >/dev/null ||
    die "helm lint failed for $env"
  # helm template leaves metadata.namespace unset; Argo CD applies into the
  # Application's namespace, so set it (the policies match on namespace).
  helm template app charts/orders-gateway -f "environments/$env/values.yaml" --namespace "$env" |
    NS="$env" yq '(select(.metadata.namespace == null) | .metadata.namespace) = strenv(NS)' >"$OUT/app-$env.yaml"
  ok "$env: $(grep -c '^kind:' "$OUT/app-$env.yaml") objects"
done
helm template app charts/orders-gateway -f environments/prod/values.yaml --namespace demo \
  --set rollout.enabled=true | yq '(select(.metadata.namespace == null) | .metadata.namespace) = "demo"' >"$OUT/app-canary.yaml"
# One file for kyverno apply (its CLI takes one --resource reliably).
mkdir -p out/policy-input
cat "$OUT"/app-dev.yaml "$OUT"/app-staging.yaml "$OUT"/app-prod.yaml "$OUT"/app-canary.yaml >out/policy-input/apps.yaml
ok "canary (demo): $(grep -c '^kind:' "$OUT/app-canary.yaml") objects"

step "The app-of-apps (gitops/apps)"
helm lint gitops/apps --set repo.url=https://example.invalid/repo.git --set repo.revision=main --quiet >/dev/null ||
  die "helm lint failed for gitops/apps"
helm template root gitops/apps --set repo.url=https://example.invalid/repo.git --set repo.revision=main >"$OUT/apps.yaml"
ok "$(grep -c '^kind:' "$OUT/apps.yaml") Applications"

step "gitops/manifests"
for d in gitops/manifests/*/; do
  n=$(basename "$d")
  if [ -f "$d/kustomization.yaml" ]; then
    kubectl kustomize "$d" >"$OUT/manifests-$n.yaml"
  else
    for f in "$d"*.yaml; do cat "$f"; printf '\n---\n'; done >"$OUT/manifests-$n.yaml"
  fi
  ok "$n: $(grep -c '^kind:' "$OUT/manifests-$n.yaml") objects"
done
