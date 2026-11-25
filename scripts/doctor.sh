#!/usr/bin/env bash
# ./platform doctor: checks the machine can run the stack. Exits non-zero only
# on problems that would make `up` fail; resource shortfalls are warnings.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

errors=0
step "Checking this machine"

# Docker itself was checked by ./platform before the toolbox started.
info=$(docker info --format '{{.ServerVersion}}|{{.NCPU}}|{{.MemTotal}}|{{.Architecture}}|{{.OperatingSystem}}')
IFS='|' read -r version ncpu memtotal arch os <<<"$info"
ok "Docker $version running ($os)"

case "$arch" in
  x86_64|amd64)  ok "Architecture: amd64" ;;
  aarch64|arm64) ok "Architecture: arm64" ;;
  *) fail "Architecture $arch is not supported (need amd64 or arm64)"; errors=$((errors + 1)) ;;
esac

if [ "$ncpu" -ge "$BUDGET_CPUS" ]; then
  ok "CPUs available to Docker: $ncpu"
else
  warn "Docker has $ncpu CPUs; the stack is sized for $BUDGET_CPUS. It may be slow or not fit."
fi

mem_gib=$(awk -v b="$memtotal" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')
# Docker reports a little under the configured size (kernel reserve), so
# accept 95% of the budget.
if awk -v m="$memtotal" -v b="$BUDGET_MEM_GB" 'BEGIN { exit !(m >= b * 1024^3 * 0.95) }'; then
  ok "Memory available to Docker: ${mem_gib} GiB"
else
  warn "Docker has ${mem_gib} GiB of memory; the stack is sized for ${BUDGET_MEM_GB} GiB. Pods may be evicted."
fi

# Free disk where Docker stores images, measured from a throwaway container.
free_kb=$(docker run --rm -v /var/lib/docker:/d:ro --entrypoint df "$TOOLBOX_IMAGE" -Pk /d 2>/dev/null | awk 'NR == 2 { print $4 }' || true)
if [ -n "$free_kb" ]; then
  free_gb=$((free_kb / 1024 / 1024))
  if [ "$free_gb" -ge 20 ]; then
    ok "Free disk for Docker: ${free_gb} GB"
  else
    warn "Only ${free_gb} GB free for Docker; images for the full stack need about 20 GB."
  fi
else
  warn "Could not measure free disk for Docker; make sure about 20 GB is free."
fi

for port in 80 443 8080 3000 9090 9093; do
  if ! nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; then
    ok "Port $port is free"
  elif cluster_exists; then
    ok "Port $port is in use by this platform's cluster"
  else
    fail "Port $port is already in use. Stop whatever is listening on it, then re-run."
    errors=$((errors + 1))
  fi
done

if cluster_exists; then
  ok "Cluster '$CLUSTER_NAME' exists ($(node_containers | wc -l | tr -d ' ') nodes)"
else
  ok "No cluster yet; run ./platform up"
fi

if [ "$errors" -gt 0 ]; then
  printf '\n%s%d problem(s) found.%s Fix them and run ./platform doctor again.\n' "$RED" "$errors" "$RESET"
  exit 1
fi
printf '\n%sReady.%s\n' "$GREEN" "$RESET"
