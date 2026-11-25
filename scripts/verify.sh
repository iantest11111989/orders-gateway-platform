#!/usr/bin/env bash
# ./platform verify: checks that the running stack does what the brief's
# definition of done says (section 14), and says which check failed:
#   1. every Argo CD Application is Synced and Healthy
#   2. every Prometheus scrape target is up
#   3. Loki has logs from every namespace that runs pods
#   4. HTTPS answers on every hostname (scripts/check-https.sh)
#   5. Kyverno rejects a bad manifest at admission (a server-side dry run of
#      a :latest pod in orders-dev must be denied by disallow-latest-tag)
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
  down=$(jq -r '.data.result[] | select(.value[1] == "0") | "\(.metric.job) \(.metric.namespace // "-") \(.metric.pod // "-") \(.metric.instance)"' <<<"$res")
  real=0 ignored=0
  while read -r job ns pod instance; do
    [ -n "$job" ] || continue
    # A pod that is gone or terminating (an old replica still draining, e.g.
    # the Envoy proxy after its bootstrap rollout: 360 s grace period) isn't a
    # problem with the running stack: note it, don't fail on it.
    if [ "$pod" != "-" ]; then
      if ! since=$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.deletionTimestamp}' 2>&1); then
        # Only a definite NotFound counts as gone; any other error (API,
        # RBAC) leaves the target counted as down.
        if [[ $since == *NotFound* || $since == *"not found"* ]]; then
          warn "target down: $job $ns/$pod: the pod is gone (ignored)"; ignored=$((ignored + 1)); continue
        fi
        miss "target down: $job $ns/$pod (and couldn't check the pod: $since)"; real=1; continue
      elif [ -n "$since" ]; then
        warn "target down: $job $ns/$pod: the pod is terminating since $since (ignored)"; ignored=$((ignored + 1)); continue
      fi
    fi
    if [ "$pod" = "-" ]; then miss "target down: $job $instance"; else miss "target down: $job $ns/$pod"; fi
    real=1
  done <<<"$down"
  if [ "$total" -eq 0 ]; then miss "Prometheus has no targets yet"
  elif [ "$real" -eq 0 ] && [ "$ignored" -gt 0 ]; then pass "$((total - ignored)) targets up ($ignored down on pods that are going away)"
  elif [ "$real" -eq 0 ]; then pass "$total targets up"; fi
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

step "Kyverno rejects a bad manifest at admission"
# Server-side dry run: nothing is created. orders-dev enforces Pod Security
# "restricted", which runs before Kyverno's webhook and stops at the first
# rejection, so the pod meets it (and the Audit policies): the :latest tag
# is the only thing wrong with it.
latest_pod='{
  "apiVersion": "v1",
  "spec": {
    "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "verify-latest-tag", "image": "docker.io/library/busybox:latest",
      "securityContext": {"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": {"drop": ["ALL"]}},
      "resources": {"requests": {"cpu": "10m", "memory": "16Mi"}, "limits": {"memory": "32Mi"}}}]}}'
if out=$(kubectl -n orders-dev run verify-latest-tag --image=docker.io/library/busybox:latest \
    --restart=Never --dry-run=server -o name --overrides="$latest_pod" 2>&1); then
  miss "Kyverno let a :latest pod into orders-dev (is it running? disallow-latest-tag is Deny there)"
elif grep -q 'disallow-latest-tag' <<<"$out"; then
  pass "a :latest pod in orders-dev was rejected by disallow-latest-tag"
elif grep -q 'PodSecurity' <<<"$out"; then
  miss "Pod Security rejected the test pod before Kyverno saw it (fix its securityContext): $out"
else
  miss "a :latest pod in orders-dev failed for another reason: $out"
fi

echo
[ "$failed" -eq 0 ] || die "$failed check(s) failed"
ok "all checks passed"
