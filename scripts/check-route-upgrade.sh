#!/usr/bin/env bash
# Upgrade check for the prod HTTPRoute. A fresh `./platform up` creates the
# route with its stable/canary backends at once, so it never exercises an
# upgrade. This puts the route back the way it was before the canary (one
# backend, the main Service, as last applied by Argo CD), asks Argo CD to sync
# orders-prod, and requires the stable/canary backends to come back with the
# app Synced. (The ignoreDifferences on orders-prod must not hold back Git's
# changes to the route; see gitops/apps/templates/orders-prod.yaml.)
# Runs in the toolbox (./platform shell scripts/check-route-upgrade.sh); CI
# runs it after ./platform up.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# APP/NS let the check run against a scratch Application.
app=${APP:-orders-prod}
ns=${NS:-orders-prod}
route=orders-gateway
tracking="$app:gateway.networking.k8s.io/HTTPRoute:$ns/$route"

backends() {
  kubectl -n "$ns" get httproute "$route" \
    -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name} {end}'
}

step "Prod HTTPRoute: back to the single pre-canary backend"
hostname=$(kubectl -n "$ns" get httproute "$route" -o jsonpath='{.spec.hostnames[0]}')
labels=$(kubectl -n "$ns" get httproute "$route" -o json | jq -c '.metadata.labels')
jq -n --arg ns "$ns" --arg route "$route" --arg host "$hostname" \
  --arg tracking "$tracking" --argjson labels "$labels" '{
  apiVersion: "gateway.networking.k8s.io/v1", kind: "HTTPRoute",
  metadata: {name: $route, namespace: $ns, labels: $labels,
    annotations: {"argocd.argoproj.io/tracking-id": $tracking}},
  spec: {
    hostnames: [$host],
    parentRefs: [{name: "platform", namespace: "envoy-gateway-system", sectionName: "https"}],
    rules: [{matches: [{path: {type: "PathPrefix", value: "/"}}],
      backendRefs: [{name: $route, port: 80, weight: 1}]}]
  }}' | kubectl apply -f - >/dev/null # apply, so last-applied is the old spec too
[ "$(backends)" = "$route " ] || die "could not reset the route (backends: $(backends))"
ok "route backends: $(backends)"

step "Argo CD sync of $app"
kubectl -n argocd patch application "$app" --type merge \
  -p '{"operation":{"initiatedBy":{"username":"check-route-upgrade"},"sync":{}}}' >/dev/null

want="$route-stable $route-canary "
deadline=$(($(date +%s) + 180))
while :; do
  got=$(backends)
  sync=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}')
  phase=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.operationState.phase}')
  if [ "$got" = "$want" ] && [ "$sync" = Synced ] && [ "$phase" = Succeeded ]; then
    ok "route backends: $got; $app $sync"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "after 180 s: route backends '$got' (want '$want'), $app $sync, last sync $phase"
  fi
  sleep 5
done
