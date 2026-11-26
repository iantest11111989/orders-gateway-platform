#!/usr/bin/env bash
# Renders everything Argo CD applies (app chart per env, bootstrap/apps,
# system/*) into out/rendered/ for kubeconform and kyverno in CI, without a
# cluster. Runs in the toolbox: ./platform shell scripts/validate-manifests.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=out/rendered
rm -rf "$OUT"; mkdir -p "$OUT"

step "Helm: lint and render the app chart per environment"
for env in dev staging prod; do
  helm lint helm/orders-gateway -f cd/orders-gateway/values.yaml -f "cd/orders-gateway/$env.yaml" --namespace "$env" --quiet >/dev/null ||
    die "helm lint failed for $env"
  # helm template leaves metadata.namespace unset; the policies match on it.
  helm template orders-gateway helm/orders-gateway -f cd/orders-gateway/values.yaml -f "cd/orders-gateway/$env.yaml" --namespace "$env" |
    NS="$env" yq '(select(.metadata.namespace == null) | .metadata.namespace) = strenv(NS)' >"$OUT/app-$env.yaml"
  ok "$env: $(grep -c '^kind:' "$OUT/app-$env.yaml") objects"
done
# One file: the kyverno CLI takes one --resource reliably.
mkdir -p out/policy-input
cat "$OUT"/app-dev.yaml "$OUT"/app-staging.yaml "$OUT"/app-prod.yaml >out/policy-input/apps.yaml

step "The app-of-apps (bootstrap/apps)"
helm lint bootstrap/apps --quiet >/dev/null || die "helm lint failed for bootstrap/apps"
helm template root bootstrap/apps >"$OUT/apps-in-stack.yaml"
ok "$(grep -c '^kind:' "$OUT/apps-in-stack.yaml") Applications"

step "system/<component> manifests"
for c in system/*/; do
  n=$(basename "$c")
  if [ -d "${c}manifests" ]; then d="${c}manifests/"
  elif [ -f "${c}values.yaml" ]; then continue # Helm values only
  else d=$c
  fi
  if [ -f "$d/kustomization.yaml" ]; then
    kubectl kustomize "$d" >"$OUT/manifests-$n.yaml"
  else
    for f in "$d"*.yaml; do cat "$f"; printf '\n---\n'; done >"$OUT/manifests-$n.yaml"
  fi
  ok "$n: $(grep -c '^kind:' "$OUT/manifests-$n.yaml") objects"
done
