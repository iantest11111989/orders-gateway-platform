#!/usr/bin/env bash
# Smoke test of the app image (CI · app, "3 · Smoke test the image"): run the
# built container the way Kubernetes runs it (non-root, read-only root
# filesystem, no capabilities) and check the behaviour the chart relies on:
#   - /healthz answers at once; /readyz is 503 during the 3 s warm-up, then 200
#     (the startupProbe and readinessProbe, charts/orders-gateway)
#   - /version, /work, POST /echo serve; unknown paths are 404
#   - /metrics has the series the SLOs and dashboards read (decision 0027)
#   - SIGTERM drains: an in-flight request finishes with 200, /readyz turns
#     503, and the process exits 0 well inside the 35 s grace period
# Usage: scripts/smoke-test-image.sh <image>   (expects VERSION=ci baked in)
set -euo pipefail
IMAGE=${1:?usage: $0 <image>}
NAME=smoke-$$
PORT=${SMOKE_PORT:-18080}
URL=http://127.0.0.1:$PORT
fails=0
ok()   { printf '  ✓ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; fails=$((fails + 1)); }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Start $IMAGE as Kubernetes would (uid 1000, read-only, no capabilities)"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" \
  --user 1000:1000 --read-only --cap-drop ALL --security-opt no-new-privileges \
  "$IMAGE" >/dev/null

echo "==> Start-up"
for _ in $(seq 1 50); do [ "$(code "$URL/healthz")" = 200 ] && break; sleep 0.1; done
c=$(code "$URL/healthz"); [ "$c" = 200 ] && ok "/healthz 200 as soon as it listens" || bad "/healthz answered $c"
c=$(code "$URL/readyz"); [ "$c" = 503 ] && ok "/readyz 503 during the warm-up" || bad "/readyz answered $c during the warm-up (want 503)"
t0=$(date +%s)
for _ in $(seq 1 100); do [ "$(code "$URL/readyz")" = 200 ] && break; sleep 0.1; done
c=$(code "$URL/readyz"); waited=$(( $(date +%s) - t0 ))
[ "$c" = 200 ] && ok "/readyz 200 after the warm-up (~${waited} s)" || bad "/readyz still $c after 10 s"

echo "==> Endpoints"
v=$(curl -s --max-time 5 "$URL/version" || true)
grep -q '"version":"ci"' <<<"$v" && ok "/version reports the build's version: $v" || bad "/version: $v"
c=$(code "$URL/work?ms=20"); [ "$c" = 200 ] && ok "GET /work 200" || bad "GET /work answered $c"
e=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"smoke":1}' "$URL/echo" || true)
[ "$e" = '{"smoke":1}' ] && ok "POST /echo returns its body" || bad "POST /echo returned: $e"
c=$(code "$URL/no-such-path"); [ "$c" = 404 ] && ok "unknown path 404" || bad "unknown path answered $c"

echo "==> Metrics"
m=$(curl -s --max-time 5 "$URL/metrics" || true)
for want in 'http_requests_total{route="/work",method="GET",status="200"}' \
            'http_requests_total{route="/echo",method="POST",status="200"}' \
            'http_request_duration_seconds_bucket{route="/echo",le="0.25"}' \
            'app_info{version="ci"}' 'app_ready 1' 'app_inflight_requests'; do
  grep -qF "$want" <<<"$m" && ok "/metrics has $want" || bad "/metrics lacks $want"
done

echo "==> Shutdown (SIGTERM, as Kubernetes sends after preStop)"
slow=$(mktemp)
curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/work?ms=1500" >"$slow" &
inflight=$!
sleep 0.3
t0=$(date +%s)
docker kill --signal TERM "$NAME" >/dev/null
sleep 0.2
c=$(code "$URL/readyz"); case "$c" in 503|000) ok "/readyz $c while draining (no new traffic)";; *) bad "/readyz answered $c while draining";; esac
wait "$inflight" || true
[ "$(cat "$slow")" = 200 ] && ok "the in-flight request finished with 200" || bad "the in-flight request got $(cat "$slow")"
rm -f "$slow"
exit_code=$(docker wait "$NAME")
took=$(( $(date +%s) - t0 ))
[ "$exit_code" = 0 ] && ok "exited 0 after ${took} s (grace period: 35 s)" || bad "exited $exit_code after ${took} s"
docker logs "$NAME" 2>&1 | grep -q '"msg":"drained, exiting"' && ok "logged \"drained, exiting\"" || bad "no \"drained, exiting\" log line"

echo
if [ "$fails" -eq 0 ]; then echo "smoke test passed"; else echo "smoke test: $fails check(s) failed"; docker logs "$NAME" 2>&1 | tail -20; exit 1; fi
