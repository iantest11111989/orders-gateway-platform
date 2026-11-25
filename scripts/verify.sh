#!/usr/bin/env bash
# ./platform verify: checks that the running stack does what the brief's
# definition of done says (section 14), and says which check failed:
#   1. every Argo CD Application is Synced and Healthy
#   2. every Prometheus scrape target is up
#   3. Loki has logs from every namespace that runs pods
#   4. HTTPS answers on every hostname (scripts/check-https.sh)
#   5. Kyverno flags a bad manifest at admission (Audit mode: a server-side
#      dry run of a :latest pod must count as a disallow-latest-tag failure)
# Prometheus, Loki and Kyverno are reached through the API server's service
# proxy, so nothing needs a port-forward. Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

failed=0
pass() { ok "$*"; }
miss() { fail "$*"; failed=$((failed + 1)); }
proxy() { kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"; }

step "Argo CD: every Application Synced and Healthy"
apps=$(kubectl -n argocd get applications.argoproj.io \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}')
[ -n "$apps" ] || miss "no Applications found (is the cluster up?)"
bad=$(awk '$2 != "Synced" || $3 != "Healthy"' <<<"$apps")
if [ -z "$bad" ]; then pass "$(grep -c . <<<"$apps") Applications Synced and Healthy"
else while read -r n s h; do miss "$n: ${s:-Unknown}, ${h:-Unknown}"; done <<<"$bad"; fi

step "Prometheus: every scrape target up"
if res=$(proxy monitoring kube-prometheus-stack-prometheus:9090 '/api/v1/query?query=up' 2>/dev/null); then
  total=$(jq '.data.result | length' <<<"$res")
  down=$(jq -r '.data.result[] | select(.value[1] == "0") | "\(.metric.job) \(.metric.namespace // "-")/\(.metric.pod // .metric.instance)"' <<<"$res")
  if [ "$total" -gt 0 ] && [ -z "$down" ]; then pass "$total targets up"
  elif [ "$total" -eq 0 ]; then miss "Prometheus has no targets yet"
  else while read -r t; do miss "target down: $t"; done <<<"$down"; fi
else
  miss "Prometheus not reachable (monitoring/kube-prometheus-stack-prometheus)"
fi

step "Loki: logs from every namespace that runs pods (last 24 h)"
want=$(kubectl get pods -A --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u)
if have=$(proxy logging loki:3100 '/loki/api/v1/label/namespace/values?since=24h' 2>/dev/null | jq -r '.data[]?'); then
  missing=$(comm -23 <(echo "$want") <(sort -u <<<"$have"))
  if [ -z "$missing" ]; then pass "$(grep -c . <<<"$want") namespaces have logs"
  else while read -r n; do miss "no logs from namespace $n"; done <<<"$missing"; fi
else
  miss "Loki not reachable (logging/loki)"
fi

step "HTTPS on every hostname"
https_log=$(mktemp)
trap 'rm -f "$https_log"' EXIT
if "$(dirname "$0")/check-https.sh" >"$https_log" 2>&1; then
  pass "every hostname answers over HTTPS with the demo CA"
else
  cat "$https_log"
  miss "HTTPS check failed (output above)"
fi

step "Kyverno flags a bad manifest at admission"
fails() {
  proxy kyverno kyverno-svc-metrics:8000 /metrics 2>/dev/null |
    awk '/^kyverno_validating_policy_results_total\{/ && /policy_name="disallow-latest-tag"/ && /result="fail"/ && /resource_namespace="default"/ { s += $NF } END { print s + 0 }'
}
before=$(fails)
kubectl -n default run verify-latest-tag --image=docker.io/library/busybox:latest \
  --restart=Never --dry-run=server -o name >/dev/null 2>&1 || true
after=$before
for _ in 1 2 3 4 5; do after=$(fails); [ "$after" -gt "$before" ] && break; sleep 2; done
if [ "$after" -gt "$before" ]; then
  pass "a :latest pod (server-side dry run) counted as a disallow-latest-tag failure"
else
  miss "Kyverno didn't flag a :latest pod (disallow-latest-tag fails stayed at $before)"
fi

echo
[ "$failed" -eq 0 ] || die "$failed check(s) failed"
ok "all checks passed"
