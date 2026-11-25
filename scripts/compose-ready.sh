#!/usr/bin/env bash
# The Compose `ready` service: bootstrap the platform, write the kubeconfig for
# the host, then stay up so the healthcheck (scripts/ready-check.sh) can report
# readiness. Safe to re-run: `docker compose stop`/`start` runs it again
# against the existing cluster.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
rm -f /tmp/bootstrapped

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
exec sleep infinity
