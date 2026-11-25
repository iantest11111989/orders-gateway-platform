#!/usr/bin/env bash
# ./platform budget [--watch SECONDS]: proves the stack fits the brief's
# 6 CPU / 12 GiB budget (section 3), measured, not estimated.
#   1. The kind node containers' hard caps (docker update in up.sh) add up
#      to no more than 6 CPU / 12 GiB, so the cluster can't use more.
#   2. What the nodes actually use now (docker stats), per node and in total.
#   3. Which namespaces use it (metrics-server, `kubectl top`).
#   4. No container was OOM-killed: a cap that's too small shows up there.
# With --watch SECONDS it samples every 5 s for that long and reports the
# peak, e.g. while a demo runs in another terminal. Runs in the toolbox.
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

# docker stats prints memory like 1.5GiB / 4GiB; turn the used part into MiB.
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

step "Peak memory per node since it started (cgroup v2 memory.peak)"
for n in "${nodes[@]}"; do
  peak=$(docker exec "$n" cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)
  cap=$(docker exec "$n" cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
  if [ -n "${peak:-}" ] && [[ ${cap:-} =~ ^[0-9]+$ ]]; then
    ok "$(printf '%-20s %6d of %d MiB (%d%%)' "$n" $((peak / 1048576)) $((cap / 1048576)) $((peak * 100 / cap)))"
  else
    warn "$n: no memory.peak (needs cgroup v2 and kernel >= 5.19)"
  fi
done

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
# Containers and init containers of current pods (a pod that was replaced
# since isn't seen here; its OOM kill shows in Prometheus as
# kube_pod_container_status_last_terminated_reason while it lasted).
oom=$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.initContainerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{range .status.containerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{"|"}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null |
  awk -F'|' '$1 ~ /OOMKilled/ {print $2}')
# A node container at its cap can lose kubelet or containerd itself, with
# nothing in any pod's status. memory.events.local counts only the node's own
# cgroup hitting its cap (cgroup v2), unlike docker inspect's OOMKilled, which
# a pod's OOM kill inside the node also sets.
for n in "${nodes[@]}"; do
  kills=$(docker exec "$n" sh -c 'awk "\$1 == \"oom_kill\" {print \$2}" /sys/fs/cgroup/memory.events.local 2>/dev/null')
  [ -n "$kills" ] && [ "$kills" -gt 0 ] && oom+=$'\n'"node container $n hit its memory cap ($kills kills)"
done
oom=$(sed '/^$/d' <<<"$oom")
if [ -z "$oom" ]; then ok "no OOM kills (containers, init containers, node containers)"
else while read -r p; do fail "OOMKilled: $p"; done <<<"$oom"; failed=1; fi

echo
[ "$failed" -eq 0 ] || die "the stack does not fit the budget (see above)"
ok "the stack fits ${BUDGET_CPU} CPU / ${BUDGET_MEM_MI} MiB"
