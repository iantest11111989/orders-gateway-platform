#!/usr/bin/env bash
# ./platform urls: every URL and login. All plain HTTP on 127.0.0.1, through
# Traefik (stack/networking/traefik/values.yaml); nothing is reachable from the LAN.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cluster_exists || die "no cluster yet; run ./platform up first"

step "orders-gateway (/admin/* is refused on every port)"
echo "  http://localhost:8080      prod"
echo "  http://localhost:8082      dev"
echo "  http://localhost:8083      staging"
echo "  http://localhost:8084      demo (while ./platform demo runs)"

step "Argo CD"
echo "  http://localhost:8081"
echo "  Login: admin / admin12345 (a demo login)"
# The toolbox sets ARGOCD_OPTS to reach Argo CD by port-forward, so the CLI
# works even if Traefik is down; no server address needed there.
echo "  CLI (inside ./platform shell): argocd login --username admin --password <above>, then argocd app list"
echo "  CLI on your machine: argocd login localhost:8081 --plaintext --grpc-web --username admin"

step "Grafana"
echo "  http://localhost:3000"
gpw=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
# From a SealedSecret sealed with the committed DEMO ONLY key.
echo "  Login: admin / ${gpw:-<not unsealed yet: re-run ./platform urls in a minute>}"

step "Prometheus and Alertmanager (no login)"
echo "  http://localhost:9090"
echo "  http://localhost:9093"
