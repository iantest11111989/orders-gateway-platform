#!/usr/bin/env bash
# Healthcheck of the Compose `ready` service: healthy only when the bootstrap
# has finished, every Argo CD Application is Synced and Healthy, and prod is
# serving. Quiet on success; says why on failure (docker inspect shows it).
set -euo pipefail
[ -f /tmp/bootstrapped ] || { echo "bootstrap still running"; exit 1; }

not_ready=$(kubectl -n argocd get applications.argoproj.io -o json |
  jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") |
    "\(.metadata.name) \(.status.sync.status)/\(.status.health.status)"')
[ -z "$not_ready" ] || { echo "not Synced/Healthy: $not_ready"; exit 1; }

# prod's endpoint, through the gateway.
curl -fsS -o /dev/null --max-time 5 -k --resolve orders.localtest.me:443:127.0.0.1 \
  https://orders.localtest.me/healthz || { echo "prod isn't serving"; exit 1; }
