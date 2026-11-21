#!/usr/bin/env bash
# ./platform urls: every URL and login. Services are added as their PRs land.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cluster_exists || die "no cluster yet; run ./platform up first"

pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

step "Argo CD"
echo "  Until the gateway PR adds https://argocd.localtest.me, open it with a port-forward:"
echo "    ./platform kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8080:80"
echo "    then http://localhost:8080"
echo "  Login: admin / ${pw:-<not found: run ./platform up>}"
