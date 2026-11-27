#!/usr/bin/env bash
# Shared helpers for the scripts ./platform runs inside the toolbox.
# shellcheck disable=SC2034
set -euo pipefail

CLUSTER_NAME=platform-demo
KIND_CONFIG=stack/cluster/kind.yaml
BUDGET_CPUS=6
BUDGET_MEM_GB=12
# Per-node cap: 3 nodes x 2 CPU / 4 GiB = the 6 CPU / 12 GiB budget.
NODE_CPUS=2
NODE_MEM_MI=4096
NODE_MEM="${NODE_MEM_MI}m"
# Kubelet eviction headroom, so pods are evicted before the cgroup OOM killer fires.
EVICTION_MEM_MI=200

if [ -t 1 ]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RESET=$'\e[0m'
else
  BOLD="" RED="" GREEN="" YELLOW="" RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
# A command, printed before it runs ("$ ..."), and a note under it. On
# stderr, so a script whose stdout is captured (registry.sh digest) stays clean.
if [ -t 2 ]; then CMDC=$'\e[36m' DIMC=$'\e[2m' RSTC=$'\e[0m'; else CMDC='' DIMC='' RSTC=''; fi
showcmd() { printf '  %s$ %s%s\n' "$CMDC" "$*" "$RSTC" >&2; }
shownote() { printf '    %s# %s%s\n' "$DIMC" "$*" "$RSTC" >&2; }

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

node_containers() {
  docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}' | sort
}

# Per-env Applications moved from the app-of-apps to the ApplicationSet. On an
# older cluster, mark them Prune=false so the root doesn't delete them (and
# their workloads via the finalizer) before the ApplicationSet adopts them.
hand_over_app_applications() {
  local dir app owner
  for dir in "$(dirname "${BASH_SOURCE[0]}")"/../apps/*/cd/; do
    for app in "$(basename "${dir%/cd/}")"-{dev,staging,prod}; do
      owner=$(kubectl -n argocd get applications.argoproj.io "$app" \
        -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null) || continue
      [ "$owner" = ApplicationSet ] && continue
      kubectl -n argocd annotate applications.argoproj.io "$app" --overwrite \
        argocd.argoproj.io/sync-options=Prune=false >/dev/null
      ok "$app: handed over to the ApplicationSet apps (its workloads stay)"
    done
  done
}

# Sync like the UI button: prune, the app's own syncOptions (a hand-written
# operation doesn't pick them up) and the automated retries. No argocd login.
sync_app() { # sync_app <application> [who]
  local opts
  opts=$(kubectl -n argocd get applications.argoproj.io "$1" -o json | jq -c '.spec.syncPolicy.syncOptions // []')
  showcmd "kubectl -n argocd patch applications.argoproj.io $1 --type merge -p '{\"operation\":{\"sync\":{\"prune\":true,\"syncOptions\":$opts}}}'"
  shownote "what Argo CD's Sync button does: an operation on the Application"
  kubectl -n argocd patch applications.argoproj.io "$1" --type merge -p "$(jq -nc --arg who "${2:-pipeline}" --argjson opts "$opts" '
    {operation: {initiatedBy: {username: $who},
                 sync: {prune: true, syncOptions: $opts},
                 retry: {limit: 5, backoff: {duration: "5s", factor: 2, maxDuration: "1m"}}}}')" >/dev/null
}

# hello-world exists only while ./platform demo hello-world has added it
# (apps/hello-world, marked by .build/hello-world-demo). Starting or deleting
# the platform drops a copy an earlier demo left in this checkout, so
# `docker compose up` deploys orders-gateway only. A folder without the
# marker is someone's own app and is left alone.
drop_demo_copies() {
  local root marker f
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  marker="$root/.build/hello-world-demo"
  [ -f "$marker" ] || return 0
  rm -rf "$root/apps/hello-world"
  # The demo hid the folder from your git (.git/info/exclude); unhide it.
  f=$(git -c safe.directory='*' -C "$root" rev-parse --git-path info/exclude 2>/dev/null || true)
  case $f in /*) ;; ?*) f="$root/$f" ;; esac
  if [ -n "$f" ] && [ -f "$f" ]; then
    grep -v -e '^# ./platform demo hello-world' -e '^/apps/hello-world/$' "$f" >"$f.tmp" || true
    mv "$f.tmp" "$f"
  fi
  rm -f "$marker"
  ok "removed the hello-world app an earlier demo left in apps/ (./platform demo hello-world adds it again)"
}
