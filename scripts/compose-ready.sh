#!/usr/bin/env bash
# The Compose `ready` service: bootstrap, write the host kubeconfig, then stay
# up for the healthcheck (scripts/ready-check.sh). Re-run on every start.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
rm -f /tmp/bootstrapped /tmp/installed-once

# Retry: a cold start can fail on a registry hiccup.
until bash scripts/up.sh; do
  warn "bootstrap failed; retrying in 30 s"
  sleep 30
done

step "Writing ./out/kubeconfig.yaml"
mkdir -p out
kind get kubeconfig --name "$CLUSTER_NAME" >out/kubeconfig.yaml.tmp
# The toolbox runs as root; demo-only admin credential for a 127.0.0.1 cluster.
chmod 0644 out/kubeconfig.yaml.tmp
mv out/kubeconfig.yaml.tmp out/kubeconfig.yaml
ok "kubectl --kubeconfig out/kubeconfig.yaml get nodes"

touch /tmp/bootstrapped
ok "bootstrap done; the healthcheck now decides when the platform is ready"

# If the cluster disappears (two misses in a row), exit so the restart policy
# rebuilds it. `sleep & wait` so SIGTERM isn't held up by the sleep.
missing=0
while sleep 30 & wait $!; do
  if docker inspect "$CLUSTER_NAME-control-plane" >/dev/null 2>&1; then
    missing=0
  else
    missing=$((missing + 1))
  fi
  if [ "$missing" -ge 2 ]; then
    warn "the kind cluster '$CLUSTER_NAME' is gone; exiting so Compose restarts this service and rebuilds it"
    exit 1
  fi
done
