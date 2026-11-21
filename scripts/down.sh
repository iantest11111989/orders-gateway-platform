#!/usr/bin/env bash
# ./platform down: deletes the cluster and local state. Safe to re-run.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

if cluster_exists; then
  step "Deleting kind cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  step "No cluster named '$CLUSTER_NAME'; nothing to delete"
fi
rm -f "$KUBECONFIG"  # in the ogp-kube volume
ok "Done"
