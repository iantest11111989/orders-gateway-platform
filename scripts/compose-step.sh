#!/usr/bin/env bash
# Healthcheck of Compose's progress services (decision 0026). `docker compose
# up -d --wait` only shows each container's state, so a single `ready` reads
# "Waiting" for ten minutes. step-1..step-4 each turn healthy when one stage
# of the bootstrap is done, so the stages tick off one by one:
#   cluster    the kind nodes are Ready
#   argocd     Argo CD is running (and the in-stack Git server, unless
#              Argo CD follows GitHub)
#   platform   every platform Application is Synced and Healthy
#   apps       dev, staging and prod are Synced and Healthy
# `ready` (scripts/ready-check.sh) still decides when the platform is ready.
# Like it, a step stays healthy once passed, and then costs one `docker
# inspect`, until the cluster is replaced: then it checks again. For the full story: docker compose logs -f ready
set -euo pipefail
DONE=/tmp/step-done
# The marker holds the cluster it was earned on: a rebuilt cluster (new
# control-plane container) makes every step check again from the start.
cluster_id=$(docker inspect -f '{{.Id}}' ogp-control-plane 2>/dev/null || true)
if [ -n "$cluster_id" ] && [ -f "$DONE" ] && [ "$(cat "$DONE")" = "$cluster_id" ]; then exit 0; fi
rm -f "$DONE"

# Every Application's name, sync and health, small enough for --argjson.
apps() {
  kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null |
    jq -c '[.items[] | {n: .metadata.name, s: .status.sync.status, h: .status.health.status}]'
}

# Applications the root Application lists (so ones not created yet count as
# not ready), matching a jq filter on their name, that aren't Synced/Healthy.
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
    # The in-stack Git server only exists when Argo CD follows it, not in
    # GitHub mode (REPO_URL set, decision 0029).
    case "$url" in *.git.svc*) running git/soft-serve ;; esac ;;
  platform)
    left=$(not_ready '^(?!(dev|staging|prod)$)')
    [ -z "$left" ] || { echo "not Synced/Healthy yet: $(tr "\n" " " <<<"$left")"; exit 1; } ;;
  apps)
    left=$(not_ready '^(dev|staging|prod)$')
    [ -z "$left" ] || { echo "not Synced/Healthy yet: $(tr "\n" " " <<<"$left")"; exit 1; } ;;
  *) echo "usage: $0 cluster|argocd|platform|apps" >&2; exit 2 ;;
esac
[ -z "$cluster_id" ] || echo "$cluster_id" >"$DONE"
