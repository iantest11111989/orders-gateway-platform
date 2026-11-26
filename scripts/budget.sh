#!/usr/bin/env bash
# ./platform budget [--watch SECONDS]: measures the stack against its
# 6 CPU / 12 GiB budget: node caps, usage now (and peak with --watch), usage
# by namespace, and OOM kills. Runs in the toolbox.
# OOM kills are the pressure signal, not memory.peak: that includes file
# cache, which image pulls fill to the cap without real pressure.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

BUDGET_CPU=6
BUDGET_MEM_MI=12288
watch=0
case "${1:-}" in
  "") ;;
  --watch) watch=${2:?--watch needs a number of seconds}; [[ $watch =~ ^[0-9]+$ ]] || die "--watch SECONDS must be a number" ;;
  *) die "usage: ./platform budget [--watch SECONDS]" ;;
esac

cluster_exists || die "no cluster '$CLUSTER_NAME'; run ./platform up first"
mapfile -t nodes < <(node_containers)
[ "${#nodes[@]}" -gt 0 ] || die "no node containers for cluster '$CLUSTER_NAME'"
failed=0

to_mi() {
  awk -v v="$1" 'BEGIN {
    n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
    f = (u == "GiB") ? 1024 : (u == "MiB") ? 1 : (u == "KiB") ? 1 / 1024 : (u == "B") ? 1 / 1048576 : (u == "TiB") ? 1048576 : 0
    printf "%d", n * f + 0.5 }'
}
# One sample: "<cpu cores x100> <mem MiB>" per node, then a total line.
sample() {
  docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' "${nodes[@]}" |
    while read -r name cpu used _ _; do
      printf '%s %s %s\n' "$name" "${cpu%\%}" "$(to_mi "$used")"
    done
}

step "Caps on the kind node containers (budget: ${BUDGET_CPU} CPU / ${BUDGET_MEM_MI} MiB)"
cap_cpu_m=0 cap_mem_mi=0
for n in "${nodes[@]}"; do
  read -r nano mem < <(docker inspect -f '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' "$n")
  if [ "$nano" -eq 0 ] || [ "$mem" -eq 0 ]; then
    fail "$n has no CPU or memory cap (was it created by ./platform up?)"; failed=1; continue
  fi
  cpu_m=$((nano / 1000000)) mem_mi=$((mem / 1048576))
  cap_cpu_m=$((cap_cpu_m + cpu_m)) cap_mem_mi=$((cap_mem_mi + mem_mi))
  ok "$(printf '%-20s %5.2f CPU  %6d MiB' "$n" "$(awk -v m="$cpu_m" 'BEGIN{print m/1000}')" "$mem_mi")"
done
if [ "$cap_cpu_m" -le $((BUDGET_CPU * 1000)) ] && [ "$cap_mem_mi" -le "$BUDGET_MEM_MI" ]; then
  ok "$(printf 'total caps %.2f CPU / %d MiB: within budget' "$(awk -v m="$cap_cpu_m" 'BEGIN{print m/1000}')" "$cap_mem_mi")"
else
  fail "total caps $cap_cpu_m mCPU / $cap_mem_mi MiB exceed ${BUDGET_CPU} CPU / ${BUDGET_MEM_MI} MiB"; failed=1
fi

step "Usage now (docker stats)"
now=$(sample)
while read -r name cpu mem; do
  ok "$(printf '%-20s %5.2f CPU  %6d MiB' "$name" "$(awk -v c="$cpu" 'BEGIN{print c/100}')" "$mem")"
done <<<"$now"
read -r tot_cpu tot_mem < <(awk '{c += $2; m += $3} END {printf "%.2f %d\n", c / 100, m}' <<<"$now")
ok "$(printf 'total %.2f of %d CPU, %d of %d MiB (%d%%)' "$tot_cpu" "$BUDGET_CPU" "$tot_mem" "$BUDGET_MEM_MI" $((tot_mem * 100 / BUDGET_MEM_MI)))"

if [ "$watch" -gt 0 ]; then
  step "Watching for ${watch}s (a sample every 5 s)"
  peak_cpu=0 peak_mem=0 samples=0 end=$(( $(date +%s) + watch ))
  while [ "$(date +%s)" -lt "$end" ]; do
    read -r c m < <(sample | awk '{c += $2; m += $3} END {printf "%.2f %d\n", c / 100, m}')
    samples=$((samples + 1))
    peak_cpu=$(awk -v a="$peak_cpu" -v b="$c" 'BEGIN{print (b > a) ? b : a}')
    [ "$m" -gt "$peak_mem" ] && peak_mem=$m
    sleep 5
  done
  ok "$(printf 'peak over %d samples: %.2f of %d CPU, %d of %d MiB (%d%%)' "$samples" "$peak_cpu" "$BUDGET_CPU" "$peak_mem" "$BUDGET_MEM_MI" $((peak_mem * 100 / BUDGET_MEM_MI)))"
fi

step "By namespace (kubectl top, metrics-server)"
if top=$(kubectl top pods -A --no-headers 2>/dev/null) && [ -n "$top" ]; then
  awk '{ c = $3; sub(/m$/, "", c); m = $4; sub(/Mi$/, "", m); cpu[$1] += c; mem[$1] += m }
       END { for (n in cpu) printf "%6d %5d %s\n", mem[n], cpu[n], n }' <<<"$top" |
    sort -rn | while read -r mem cpu ns; do
      ok "$(printf '%-24s %5d mCPU  %6d MiB' "$ns" "$cpu" "$mem")"
    done
else
  warn "kubectl top has no data yet (metrics-server needs a minute after up)"
fi

step "Out-of-memory kills (a cap that's too small shows up here)"
# Current pods only; a replaced pod's OOM shows in Prometheus instead.
oom=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.initContainerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{range .status.containerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{"|"}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null |
  awk -F'|' '$1 ~ /OOMKilled/ {print $2}')
# Node-level OOMs (kubelet/containerd at the node cap) appear in no pod status:
# count memory.events.local's `oom`, not oom_kill (root cgroup only) or
# docker's OOMKilled (also set by pod OOMs).
for n in "${nodes[@]}"; do
  hits=$(docker exec "$n" sh -c 'awk "\$1 == \"oom\" {print \$2}" /sys/fs/cgroup/memory.events.local 2>/dev/null')
  [ -n "$hits" ] && [ "$hits" -gt 0 ] && oom+=$'\n'"node container $n hit its memory cap ($hits OOM events)"
done
oom=$(sed '/^$/d' <<<"$oom")
if [ -z "$oom" ]; then ok "no OOM kills (containers, init containers, node containers)"
else while read -r p; do fail "OOMKilled: $p"; done <<<"$oom"; failed=1; fi

echo
[ "$failed" -eq 0 ] || die "the stack does not fit the budget (see above)"
ok "the stack fits ${BUDGET_CPU} CPU / ${BUDGET_MEM_MI} MiB"
