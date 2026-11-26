#!/usr/bin/env bash
# Healthcheck of the Compose `ready` service (decision 0026): healthy only when
# the platform is fully installed and the app is serving.
#   Until the first success: the bootstrap finished, every Argo CD Application
#   is Synced and Healthy, and prod is serving.
#   After that: only prod serving. A demo, a paused canary or a short Degraded
#   moment later on shouldn't make the whole platform read as unhealthy.
# The marker is in /tmp, so restarting the container (compose stop/start)
# brings back the full check. Demo copies (label demo=true) never count: one
# kept with --keep (a canary-fail copy is Degraded by design) would otherwise
# keep `ready` unhealthy after a restart. Quiet on success; says why on failure.
set -euo pipefail
INSTALLED=/tmp/installed-once

serving() {
  # prod's readiness (503 while starting or draining), at the contract's
  # endpoint http://localhost:8080, through the Gateway.
  curl -fsS -o /dev/null --max-time 5 http://localhost:8080/readyz ||
    { echo "prod isn't serving at http://localhost:8080"; return 1; }
}

if [ -f "$INSTALLED" ]; then serving; exit; fi

[ -f /tmp/bootstrapped ] || { echo "bootstrap still running"; exit 1; }
not_ready=$(kubectl -n argocd get applications.argoproj.io -o json |
  jq -r '.items[] | select(.metadata.labels.demo != "true") |
    select(.status.sync.status != "Synced" or .status.health.status != "Healthy") |
    "\(.metadata.name) \(.status.sync.status)/\(.status.health.status)"')
[ -z "$not_ready" ] || { echo "not Synced/Healthy: $not_ready"; exit 1; }
serving
touch "$INSTALLED"
