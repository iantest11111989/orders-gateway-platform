#!/usr/bin/env bash
# Healthcheck for Compose's step-1..4 progress services (cluster, argocd,
# platform, apps), since `up --wait` shows only container states. Once passed
# a step stays healthy until the cluster is replaced.
set -euo pipefail
DONE=/tmp/step-done
# The marker holds the control-plane container ID, so a rebuilt cluster re-checks.
cluster_id=$(docker inspect -f '{{.Id}}' "${CLUSTER_NAME:-platform-demo}-control-plane" 2>/dev/null || true)
if [ -n "$cluster_id" ] && [ -f "$DONE" ] && [ "$(cat "$DONE")" = "$cluster_id" ]; then exit 0; fi
rm -f "$DONE"

apps() {
  kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null |
    jq -c '[.items[] | {n: .metadata.name, s: .status.sync.status, h: .status.health.status}]'
}

# Apps the root lists (so not-yet-created ones count) matching $1, not Synced/Healthy.
not_ready() {
  local root
  root=$(kubectl -n argocd get application root -o json 2>/dev/null) ||
    { echo "root Application not created yet"; return; }
  jq -r --argjson live "$(apps)" --arg want "$1" '
    [.status.resources[]? | select(.kind == "Application") | .name | select(test($want))] as $names
    | if ($names | length) == 0 then "Applications not listed yet" else
      $names[] as $n
      | ([$live[] | select(.n == $n)][0]) as $a
      | select($a == null or $a.s != "Synced" or $a.h != "Healthy")
      | $n end' <<<"$root" 2>/dev/null || echo "Applications not readable yet"
}

# <app>-<env> Applications (from the ApplicationSet, not listed by the root)
# not ready. Manual-sync apps count as Synced once a sync has succeeded.
apps_not_ready() {
  local want
  want=$(cd "$(dirname "$0")/.." && for f in cd/*/dev.yaml cd/*/staging.yaml cd/*/prod.yaml; do
    [ -f "$f" ] && { d=${f%/*}; e=${f##*/}; echo "${d#cd/}-${e%.yaml}"; }
  done | jq -R . | jq -sc .)
  kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null | jq -r --argjson want "$want" '
    [.items[] | {key: .metadata.name, value: .}] | from_entries as $live
    | $want[] as $n | $live[$n] as $a
    | select($a == null or $a.status.health.status != "Healthy"
        or ($a.status.sync.status != "Synced"
            and ($a.spec.syncPolicy.automated == null and $a.status.operationState.phase == "Succeeded" | not)))
    | $n' || echo "Applications not readable yet"
}

case "${1:-}" in
  cluster)
    n=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l)
    [ "$n" -ge 3 ] || { echo "kind nodes Ready: $n of 3"; exit 1; } ;;
  argocd)
    running() {
      local r
      r=$(kubectl -n "${1%/*}" get deploy "${1#*/}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
      [ "${r:-0}" -ge 1 ] || { echo "$1 not running yet"; exit 1; }
    }
    running argocd/argocd-server
    running argocd/argocd-repo-server
    url=$(kubectl -n argocd get application root -o jsonpath='{.spec.source.repoURL}' 2>/dev/null) ||
      { echo "root Application not created yet"; exit 1; }
    [ -n "$url" ] || { echo "root Application not created yet"; exit 1; }
    running git/soft-serve ;;
  platform)
    left=$(not_ready '.')
    [ -z "$left" ] || { echo "not Synced/Healthy yet: $(tr "\n" " " <<<"$left")"; exit 1; } ;;
  apps)
    left=$(apps_not_ready)
    [ -z "$left" ] || { echo "not Synced/Healthy yet: $(tr "\n" " " <<<"$left")"; exit 1; } ;;
  *) echo "usage: $0 cluster|argocd|platform|apps" >&2; exit 2 ;;
esac
[ -z "$cluster_id" ] || echo "$cluster_id" >"$DONE"
