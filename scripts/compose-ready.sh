#!/usr/bin/env bash
# The Compose `ready` service: bootstrap the platform, write the kubeconfig for
# the host, then stay up so the healthcheck (scripts/ready-check.sh) can report
# readiness. Safe to re-run: `docker compose stop`/`start` runs it again
# against the existing cluster.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
rm -f /tmp/bootstrapped /tmp/installed-once

# up.sh is idempotent; a cold start can fail on a registry hiccup, so retry
# instead of leaving the service up but never healthy.
until bash scripts/up.sh; do
  warn "bootstrap failed; retrying in 30 s"
  sleep 30
done

step "Writing ./out/kubeconfig.yaml"
mkdir -p out
kind get kubeconfig --name "$CLUSTER_NAME" >out/kubeconfig.yaml.tmp
# Readable by the host user (the toolbox runs as root). It's a local, demo-only
# admin credential for a cluster bound to 127.0.0.1.
chmod 0644 out/kubeconfig.yaml.tmp
mv out/kubeconfig.yaml.tmp out/kubeconfig.yaml
ok "kubectl --kubeconfig out/kubeconfig.yaml get nodes"

touch /tmp/bootstrapped
ok "bootstrap done; the healthcheck now decides when the platform is ready"

# Stay up for the healthcheck, and watch the cluster. If it disappears (a
# `kind delete`, an older ./platform down, Docker's VM reset), exit: the
# restart policy starts this service again and the bootstrap rebuilds the
# cluster. Two misses in a row, so a slow `docker inspect` can't trigger it.
# `sleep & wait` so SIGTERM (docker compose stop) isn't held up by the sleep.
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
