#!/usr/bin/env bash
# Variables here are used by the scripts that source this file.
# shellcheck disable=SC2034
# Shared helpers for the scripts ./platform runs inside the toolbox.
set -euo pipefail

CLUSTER_NAME=ogp
KIND_CONFIG=cluster/kind.yaml
# Budget for the whole stack.
BUDGET_CPUS=6
BUDGET_MEM_GB=12
# Per kind node container cap: 3 nodes x 2 CPU / 4 GiB = the budget.
NODE_CPUS=2
NODE_MEM_MI=4096
NODE_MEM="${NODE_MEM_MI}m"
# Kept free inside each node for kubelet eviction, so the kubelet evicts pods
# before the kernel's cgroup OOM killer fires.
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

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

node_containers() {
  docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format '{{.Names}}' | sort
}
