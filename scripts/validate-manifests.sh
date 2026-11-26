#!/usr/bin/env bash
# Renders everything Argo CD applies, so CI can validate it in seconds,
# without a cluster (CI · platform, "Validate manifests"):
#   - helm lint, then helm template of charts/orders-gateway for dev, staging
#     and prod with their values files
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
# One file for kyverno apply (its CLI takes one --resource reliably).
mkdir -p out/policy-input
cat "$OUT"/app-dev.yaml "$OUT"/app-staging.yaml "$OUT"/app-prod.yaml >out/policy-input/apps.yaml

step "The app-of-apps (gitops/apps), in both modes"
# The in-stack Git server (default) and GitHub mode: some templates (the
# promoter) render differently when repo.url is on github.com.
for mode in in-stack:http://git.git.svc.cluster.local:23232/platform.git github:https://github.com/example/repo.git; do
  name=${mode%%:*} url=${mode#*:}
  helm lint gitops/apps --set repo.url="$url" --set repo.revision=main --quiet >/dev/null ||
    die "helm lint failed for gitops/apps ($name)"
  helm template root gitops/apps --set repo.url="$url" --set repo.revision=main >"$OUT/apps-$name.yaml"
  ok "$name: $(grep -c '^kind:' "$OUT/apps-$name.yaml") Applications"
done

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
