#!/usr/bin/env bash
# ./platform verify: checks that the running stack works, and says which
# check failed:
#   1. every Argo CD Application is Synced and Healthy
#   2. every Prometheus scrape target is up
#   3. Loki has logs from every namespace that runs pods
#   4. the host ports, all plain HTTP through Traefik: prod :8080, dev :8082,
#      staging :8083 (/admin/* refused on each), Grafana :3000,
#      Prometheus :9090, Alertmanager :9093, Argo CD :8081
#   5. Kyverno rejects a bad manifest at admission (a server-side dry run of
#      a :latest pod in dev must be denied by disallow-latest-tag)
# Prometheus, Loki and Kyverno are reached through the API server's service
# proxy, so nothing needs a port-forward. Runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

failed=0
pass() { ok "$*"; }
miss() { fail "$*"; failed=$((failed + 1)); }
proxy() { kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"; }

step "Argo CD: every Application Synced and Healthy"
# Demo copies (label demo=true, ./platform demo) aren't part of the stack:
# one left with --keep may be mid-demo. Note them, don't fail on them.
# The fourth column says whether the app syncs on its own: the apps' staging
# and prod sync by hand, so OutOfSync there is a promotion waiting for its
# Sync click, not a failure (a warning; ArgoCDManualSyncPending after 1 h).
apps=$(kubectl -n argocd get applications.argoproj.io -l 'demo!=true' \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status} {.spec.syncPolicy.automated}{"\n"}{end}' |
  awk '{print $1, $2, $3, ($4 == "" ? "manual" : "auto")}')
demos=$(kubectl -n argocd get applications.argoproj.io -l demo=true \
  -o jsonpath='{range .items[*]}{.metadata.name} ({.status.sync.status}, {.status.health.status}) {end}' 2>/dev/null || true)
[ -z "$demos" ] || warn "demo copy running, not checked: $demos(./platform demo clean removes it)"
[ -n "$apps" ] || miss "no Applications found (is the cluster up?)"
pending=$(awk '$4 == "manual" && $2 == "OutOfSync" && $3 == "Healthy" {print $1}' <<<"$apps")
for n in $pending; do warn "$n: OutOfSync, waiting for a manual Sync (http://localhost:8081, or ./pipeline cd --sync)"; done
bad=$(awk '!($4 == "manual" && $2 == "OutOfSync" && $3 == "Healthy") && ($2 != "Synced" || $3 != "Healthy")' <<<"$apps")
if [ -z "$bad" ]; then
  if [ -z "$pending" ]; then pass "$(grep -c . <<<"$apps") Applications Synced and Healthy"
  else pass "$(grep -c . <<<"$apps") Applications Healthy; Synced but for $(wc -w <<<"$pending" | tr -d ' ') waiting for a manual Sync"; fi
else while read -r n s h _; do miss "$n: ${s:-Unknown}, ${h:-Unknown}"; done <<<"$bad"; fi

step "Prometheus: every scrape target up"
if res=$(proxy monitoring kube-prometheus-stack-prometheus:9090 '/api/v1/query?query=up' 2>/dev/null); then
  total=$(jq '.data.result | length' <<<"$res")
  down=$(jq -r '.data.result[] | select(.value[1] == "0") | "\(.metric.job) \(.metric.namespace // "-") \(.metric.pod // "-") \(.metric.instance)"' <<<"$res")
  real=0 ignored=0
  while read -r job ns pod instance; do
    [ -n "$job" ] || continue
    # A pod that is gone or terminating (an old replica still draining, e.g.
    # a proxy pod after a rollout, with a long grace period) isn't a
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
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | grep -vx demo | sort -u)
if have=$(proxy logging loki:3100 '/loki/api/v1/label/namespace/values?since=24h' 2>/dev/null | jq -r '.data[]?'); then
  missing=$(comm -23 <(echo "$want") <(sort -u <<<"$have"))
  if [ -z "$missing" ]; then pass "$(grep -c . <<<"$want") namespaces have logs"
  else while read -r n; do miss "no logs from namespace $n"; done <<<"$missing"; fi
else
  miss "Loki not reachable (logging/loki)"
fi

step "Alerts reach the local receiver (Watchdog heartbeat in Loki)"
# Alertmanager sends the always-firing Watchdog to alert-receiver every
# 5 minutes, which logs it: one line proves Prometheus ->
# Alertmanager -> receiver -> Loki works end to end.
q=$(jq -rn '"{namespace=\"monitoring\", app=\"alert-receiver\"} |= \"Watchdog\"" | @uri')
n=$(proxy logging loki:3100 "/loki/api/v1/query_range?query=$q&since=1h&limit=20" 2>/dev/null |
  jq '[.data.result[]?.values[]] | length' 2>/dev/null || echo 0)
if [ "${n:-0}" -gt 0 ]; then pass "Watchdog notifications delivered ($n in the last hour)"
else miss "no Watchdog notification in Loki from monitoring/alert-receiver in the last hour"; fi

step "The host ports (plain HTTP, through Traefik)"
# Runs with the host's network (the toolbox, and Compose's ready service), so
# localhost is the host's.
# curl prints 000 itself when it can't connect; don't add a second one.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }
for env_port in prod:8080 dev:8082 staging:8083; do
  env=${env_port%%:*} port=${env_port##*:}
  c=$(code "http://localhost:$port/readyz")
  if [ "$c" = 200 ]; then pass "$env serves at http://localhost:$port (/readyz 200)"
  else miss "$env at http://localhost:$port/readyz answered $c"; fi
  c=$(code -X POST -d '{}' "http://localhost:$port/admin/fault")
  if [ "$c" = 403 ]; then pass "$env: /admin/* is refused at the edge (POST /admin/fault: 403)"
  else miss "$env: POST http://localhost:$port/admin/fault answered $c, not 403: /admin must not be reachable from outside"; fi
done
# Disguised paths: the app (Node) resolves them to /admin/fault, so the edge
# must refuse them too (non-2xx). --path-as-is sends them unaltered.
for p in /x/../admin/fault //admin/fault /admin%2Ffault /%61dmin/fault /admin/./fault; do
  c=$(code --path-as-is -X POST -d '{}' "http://localhost:8080$p")
  case "$c" in
    2*) miss "POST $p answered $c: a disguised /admin path got through the edge" ;;
    *) pass "POST $p refused ($c)" ;;
  esac
done
while read -r port path name; do
  c=$(code "http://localhost:$port$path")
  if [ "$c" = 200 ]; then pass "$name on http://localhost:$port ($path 200)"
  else miss "$name at http://localhost:$port$path answered $c"; fi
done <<'EOF2'
3000 /api/health Grafana
9090 /-/ready Prometheus
9093 /-/ready Alertmanager
8081 /api/version Argo CD
EOF2
# The demo login, admin / admin12345, on each UI that has one.
c=$(code -u admin:admin12345 http://localhost:3000/api/user)
if [ "$c" = 200 ]; then pass "Grafana login admin / admin12345 works"
else miss "Grafana login admin / admin12345 answered $c"; fi
c=$(code -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin12345"}' http://localhost:8081/api/v1/session)
if [ "$c" = 200 ]; then pass "Argo CD login admin / admin12345 works"
else miss "Argo CD login admin / admin12345 answered $c"; fi

step "Kyverno rejects a bad manifest at admission"
# Server-side dry run: nothing is created. dev enforces Pod Security
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
if out=$(kubectl -n dev run verify-latest-tag --image=docker.io/library/busybox:latest \
    --restart=Never --dry-run=server -o name --overrides="$latest_pod" 2>&1); then
  miss "Kyverno let a :latest pod into dev (is it running? disallow-latest-tag is Deny there)"
elif grep -q 'disallow-latest-tag' <<<"$out"; then
  pass "a :latest pod in dev was rejected by disallow-latest-tag"
elif grep -q 'PodSecurity' <<<"$out"; then
  miss "Pod Security rejected the test pod before Kyverno saw it (fix its securityContext): $out"
else
  miss "a :latest pod in dev failed for another reason: $out"
fi

echo
[ "$failed" -eq 0 ] || die "$failed check(s) failed"
ok "all checks passed"
