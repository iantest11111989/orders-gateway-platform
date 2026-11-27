#!/usr/bin/env bash
# ./platform demo contract: checks the platform's fixed contract
# (docs/requirements.md) on the running platform: readiness, kubeconfig,
# namespaces and Deployments, the app on :8080 with /admin/* blocked, the
# UIs and their login, restart policies and what keeps data across a
# docker compose stop/start. Read-only: it changes nothing.
# Runs in the toolbox (host network, so localhost is the host's).
# "check && pass || miss" is safe here: pass (ok) never fails.
# shellcheck disable=SC2015
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

FAILED=0
pass() { ok "$*"; }
miss() { fail "$*"; FAILED=$((FAILED + 1)); }

# http <expected status> <curl args...>: show the request, its status and
# body (first lines), and check the status.
http() {
  local want=$1 out code body; shift
  show "curl -s $(qargs "$@")"
  out=$(curl -s --max-time 10 -w '\n%{http_code}' "$@" 2>&1 || true)
  code=${out##*$'\n'}; body=${out%$'\n'*}
  printf '%s\n' "$body" | grep -v '^$' | head -5 | cut -c1-150 | indent || true
  printf '      → HTTP %s\n' "$code"
  [ "$code" = "$want" ]
}

step "Demo: the fixed contract, checked on the running platform"
echo "  The names, ports and endpoints the repo promises (the contract table in"
echo "  docs/requirements.md), each checked with the command you would run by"
echo "  hand. Read-only. Takes under a minute."

# --- Readiness ----------------------------------------------------------------
step "Readiness: a Compose service named ready, healthy only when everything is up"
run docker ps -a --filter label=com.docker.compose.project=platform-demo --format 'table {{.Names}}\t{{.Status}}'
st=$(get docker inspect platform-demo-ready-1 --format '{{.State.Health.Status}}' || true)
if [ "$st" = healthy ]; then pass "ready is healthy"; else miss "ready is '${st:-missing}', not healthy"; fi
note "its healthcheck (scripts/compose-ready.sh) passes only once every Argo CD app is Synced and Healthy and prod answers on :8080"

# --- Kubeconfig ---------------------------------------------------------------
step "Kubeconfig: ./out/kubeconfig.yaml, usable from the host"
if [ -f out/kubeconfig.yaml ]; then
  run kubectl --kubeconfig out/kubeconfig.yaml get nodes -L topology.kubernetes.io/zone &&
    pass "out/kubeconfig.yaml reaches the cluster" || miss "out/kubeconfig.yaml doesn't reach the cluster"
else
  miss "no out/kubeconfig.yaml in this checkout (the checkout that ran docker compose up has it)"
fi

# --- Namespaces ---------------------------------------------------------------
step "Namespaces: dev, staging and prod each run the app"
note "the Deployment is named after its app, orders-gateway, not app (docs/naming.md)"
for ns in dev staging prod; do
  if run kubectl -n "$ns" get deployment -l app.kubernetes.io/name=orders-gateway -o wide &&
     [ "$(kubectl -n "$ns" get deployment orders-gateway -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
    pass "$ns: Deployment orders-gateway, label app.kubernetes.io/name=orders-gateway, available"
  else
    miss "$ns: no available Deployment orders-gateway"
  fi
done

# --- App endpoint -------------------------------------------------------------
step "App endpoint: prod through an Ingress on http://localhost:8080"
run kubectl -n prod get ingress
note "the app's own endpoints (apps/orders-gateway/app/server.js), all through Traefik:"
http 200 http://localhost:8080/version && pass "GET /version" || miss "GET /version"
http 200 http://localhost:8080/healthz && pass "GET /healthz" || miss "GET /healthz"
http 200 http://localhost:8080/readyz && pass "GET /readyz" || miss "GET /readyz"
http 200 'http://localhost:8080/work?ms=20' && pass "GET /work (burns 20 ms of CPU)" || miss "GET /work"
http 200 -X POST -H 'Content-Type: application/json' -d '{"order":"ord-1","items":2}' http://localhost:8080/echo &&
  pass "POST /echo" || miss "POST /echo"
show "curl -s http://localhost:8080/metrics | grep -m3 '^http_requests_total'"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/metrics || true)
curl -s --max-time 10 http://localhost:8080/metrics | grep -m3 '^http_requests_total' | indent || true
printf '      → HTTP %s\n' "$code"
[ "$code" = 200 ] && pass "GET /metrics" || miss "GET /metrics"

step "/admin/* must not be reachable from outside the cluster"
http 403 -X POST -d '{"error_rate":1}' http://localhost:8080/admin/fault &&
  pass "POST /admin/fault refused from outside (403)" || miss "POST /admin/fault is reachable from outside"
http 403 http://localhost:8080/admin/anything && pass "any /admin/* path refused (403)" || miss "/admin/* reachable"
run kubectl -n prod get middleware.traefik.io
note "Traefik's orders-gateway-admin Ingress sends /admin to a deny middleware; inside the cluster the app still serves it"

# --- UIs and logins -----------------------------------------------------------
step "Dashboards: Grafana :3000, Prometheus :9090, Alertmanager :9093 (login admin / admin12345)"
http 200 -u admin:admin12345 http://localhost:3000/api/user && pass "Grafana: logged in as admin" || miss "Grafana login"
http 401 -u admin:wrong http://localhost:3000/api/user && pass "Grafana: a wrong password is refused" || miss "Grafana accepted a wrong password"
http 200 http://localhost:9090/-/ready && pass "Prometheus ready" || miss "Prometheus"
http 200 http://localhost:9093/-/ready && pass "Alertmanager ready" || miss "Alertmanager"
note "Prometheus and Alertmanager have no login, as upstream; Argo CD (:8081) also uses admin / admin12345"

# --- Restarts and persistence ---------------------------------------------------
step "Restart policies: every long-running Compose service"
show "docker inspect --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}' <each platform-demo container>"
bad=0
while read -r name policy; do
  printf '      %-36s %s\n' "$name" "$policy"
  [ "$policy" != restart=no ] || bad=1
done < <(docker ps -aq --filter label=com.docker.compose.project=platform-demo |
  xargs docker inspect --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}' | sed 's#^/##')
[ "$bad" -eq 0 ] && pass "every Compose service has a restart policy" || miss "a Compose service has no restart policy"
run docker inspect --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}}' platform-demo-control-plane platform-demo-worker platform-demo-worker2
note "the kind node containers restart too, so the cluster comes back after a reboot of Docker"

step "Data that survives docker compose stop / start"
run kubectl get pvc -A
note "the Git server (Argo CD's source), the registry, Prometheus and Loki keep their data on these volumes, inside the kind node containers"
note "Grafana needs none: its dashboards and datasources are code (stack/observability/dashboards/), loaded at start"
note "the E2E workflow checks it: scripts/persistence-check.sh, then docker compose stop and start, then the same check again"
note "try it yourself: docker compose stop && docker compose start && ./platform demo contract"

check "the same contract, by eye (admin / admin12345)" "" \
  "http://localhost:8080/version: prod answers" \
  "$(dash_url platform-overview): Argo CD apps not Synced and not Healthy both 0, Pods not Ready 0" \
  "http://localhost:9093: only Watchdog firing, the always-on alert that proves alerting works"

echo
if [ "$FAILED" -eq 0 ]; then
  ok "every contract row checked: all pass"
else
  die "$FAILED contract check(s) failed (above)"
fi
