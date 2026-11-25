#!/usr/bin/env bash
# ./platform up: creates the kind cluster, bootstraps Argo CD and waits until
# every Application is Synced and Healthy. Safe to re-run.
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
  # The kubelet sees the whole Docker host (the Colima VM, or the Linux
  # machine), not the per-node cap below. Reserve the difference so each
  # node's allocatable fits inside its cap and the scheduler can't overcommit.
  read -r host_mem host_cpus < <(docker info --format '{{.MemTotal}} {{.NCPU}}')
  host_mem_mi=$((host_mem / 1024 / 1024))
  reserved_mem_mi=$((host_mem_mi - NODE_MEM_MI + 256))
  reserved_cpus=$((host_cpus - NODE_CPUS))
  [ "$reserved_mem_mi" -gt 0 ] || reserved_mem_mi=0
  [ "$reserved_cpus" -gt 0 ] || reserved_cpus=0

  config=$(mktemp)
  RESERVED_MEM="${reserved_mem_mi}Mi" RESERVED_CPU="$reserved_cpus" EVICTION="${EVICTION_MEM_MI}Mi" \
    yq '.kubeadmConfigPatches += [
      "kind: KubeletConfiguration\nsystemReserved:\n  memory: " + strenv(RESERVED_MEM) +
      "\n  cpu: \"" + strenv(RESERVED_CPU) + "\"\nevictionHard:\n  memory.available: " + strenv(EVICTION) + "\n"
    ]' "$KIND_CONFIG" >"$config"

  step "Creating kind cluster '$CLUSTER_NAME' (1 control plane + 2 workers)"
  ok "Docker host: ${host_cpus} CPU / ${host_mem_mi} MiB; reserving ${reserved_cpus} CPU / ${reserved_mem_mi} MiB per node so each node fits its ${NODE_CPUS} CPU / ${NODE_MEM_MI} MiB cap"
  kind create cluster --config "$config" --wait 0s
  rm -f "$config"
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

step "Checking each node's allocatable fits its cap"
over=0
while read -r name cpu mem; do
  case "$mem" in *[0-9]) mem_mi=$((mem / 1024 / 1024));; *Ki) mem_mi=$(( ${mem%Ki} / 1024 ));; *Mi) mem_mi=${mem%Mi};; *Gi) mem_mi=$(( ${mem%Gi} * 1024 ));; esac
  cpu_m=$cpu; case "$cpu" in *m) cpu_m=${cpu%m};; *) cpu_m=$((cpu * 1000));; esac
  if [ "$mem_mi" -le "$NODE_MEM_MI" ] && [ "$cpu_m" -le $((NODE_CPUS * 1000)) ]; then
    ok "$(printf '%-20s allocatable %s CPU / %s MiB' "$name" "$cpu" "$mem_mi")"
  else
    fail "$(printf '%-20s allocatable %s CPU / %s MiB is above the %s CPU / %s MiB cap' "$name" "$cpu" "$mem_mi" "$NODE_CPUS" "$NODE_MEM_MI")"
    over=1
  fi
done < <(kubectl get nodes --no-headers -o custom-columns=N:.metadata.name,C:.status.allocatable.cpu,M:.status.allocatable.memory)
if [ "$over" -ne 0 ]; then
  die "nodes advertise more than their cap, so pods could be OOM-killed. This cluster was created before reservations were added; recreate it: ./platform down && ./platform up"
fi

# CI only (PRELOAD_IMAGES, set by .github/workflows/platform.yml): import the
# cached images before Argo CD starts pulling, so a cold start doesn't hinge
# on every registry answering. Best effort; scripts/images.sh explains.
if [ -n "${PRELOAD_IMAGES:-}" ]; then
  step "Loading the image cache ($PRELOAD_IMAGES)"
  bash "$(dirname "$0")/images.sh" load "$PRELOAD_IMAGES" || warn "image cache not loaded; images will be pulled"
fi

step "Waiting for system pods"
kubectl -n kube-system wait --for=condition=Ready pods --all --timeout=180s >/dev/null
ok "kube-system healthy"

# Before Argo CD installs the Sealed Secrets controller, so it finds this key
# on first start instead of generating its own. DEMO ONLY key (decision 0018).
step "Loading the Sealed Secrets demo key"
kubectl apply -f "$(dirname "$0")/../gitops/manifests/sealed-secrets/demo-key.yaml" >/dev/null
ok "kube-system/sealed-secrets-demo-key"

echo
bash "$(dirname "$0")/argocd-bootstrap.sh"

elapsed=$(( $(date +%s) - start ))
cat <<EOF

${GREEN}Cluster is up${RESET} in ${elapsed}s.

  URLs and logins:                             ./platform urls
  Shell with kubectl, helm, argocd, k6 ready:  ./platform shell
  Delete everything:                           ./platform down
EOF
