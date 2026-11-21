#!/usr/bin/env bash
# ./platform up: creates the kind cluster and waits until it is healthy.
# Safe to re-run: an existing cluster is reused.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

start=$(date +%s)
bash "$(dirname "$0")/doctor.sh"
echo

mkdir -p "$(dirname "$KUBECONFIG")"

if cluster_exists; then
  step "Cluster '$CLUSTER_NAME' already exists; reusing it"
  kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null
else
  step "Creating kind cluster '$CLUSTER_NAME' (1 control plane + 2 workers)"
  kind create cluster --config "$KIND_CONFIG" --wait 0s
fi

# kind has no resource limits of its own, so cap each node container. Under
# Colima the VM is already capped at the budget; on Linux this keeps the stack
# within 6 CPU / 12 GiB.
step "Capping node containers at ${NODE_CPUS} CPU / ${NODE_MEM} each"
for n in $(node_containers); do
  docker update --cpus "$NODE_CPUS" --memory "$NODE_MEM" --memory-swap "$NODE_MEM" "$n" >/dev/null
  ok "$n"
done

step "Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl get nodes -L topology.kubernetes.io/zone --no-headers |
  while read -r name status roles _ _ zone; do ok "$(printf '%-20s %-6s %-14s zone=%s' "$name" "$status" "$roles" "$zone")"; done

step "Waiting for system pods"
kubectl -n kube-system wait --for=condition=Ready pods --all --timeout=180s >/dev/null
ok "kube-system healthy"

elapsed=$(( $(date +%s) - start ))
cat <<EOF

${GREEN}Cluster is up${RESET} in ${elapsed}s.

  Shell with kubectl, helm, argocd, k6 ready:  ./platform shell
  Delete everything:                           ./platform down

Argo CD and the rest of the platform arrive in the next pull requests.
EOF
