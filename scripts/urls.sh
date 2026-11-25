#!/usr/bin/env bash
# ./platform urls: every URL and login, and how to trust the demo CA.
# Services are added as their PRs land.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cluster_exists || die "no cluster yet; run ./platform up first"

# The demo CA (gitops/manifests/gateway/ca.yaml) is new on every cluster.
# Export its certificate into the repo's git-ignored .build/ for the host.
ca_file=.build/ogp-demo-ca.crt
mkdir -p .build
if kubectl -n cert-manager get secret ogp-demo-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"$ca_file.tmp" && [ -s "$ca_file.tmp" ]; then
  mv "$ca_file.tmp" "$ca_file"
else
  rm -f "$ca_file.tmp"; ca_file=
fi

step "The contract's endpoints (plain HTTP on the host)"
echo "  http://localhost:8080      the app in prod (/admin/* is refused)"
echo "  http://localhost:3000      Grafana"
echo "  http://localhost:9090      Prometheus"
echo "  http://localhost:9093      Alertmanager"
echo

step "HTTPS (demo CA)"
if [ -n "$ca_file" ]; then
  echo "  Every URL below is HTTPS with a certificate from this cluster's own demo CA."
  echo "  Either accept the browser warning, or trust the CA (DEMO ONLY; remove it after):"
  echo "    CA certificate:  $ca_file"
  echo "    macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $ca_file"
  echo "    Linux:   sudo cp $ca_file /usr/local/share/ca-certificates/ogp-demo-ca.crt && sudo update-ca-certificates"
  echo "    curl:    curl --cacert $ca_file https://grafana.localtest.me"
  echo "  Plain http:// redirects to https://."
else
  warn "demo CA not ready yet; re-run ./platform urls in a minute"
fi

pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

step "Argo CD"
echo "  https://argocd.localtest.me"
echo "  Login: admin / ${pw:-<not found: run ./platform up>}"
# The toolbox sets ARGOCD_OPTS to reach Argo CD by port-forward, so the CLI
# works even if the gateway is down; no server address needed there.
echo "  CLI (inside ./platform shell): argocd login --username admin --password <above>, then argocd app list"
echo "  CLI on your machine, through the gateway: argocd login argocd.localtest.me --grpc-web --username admin"

step "Grafana"
echo "  https://grafana.localtest.me"
gpw=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
# From a SealedSecret sealed with the committed DEMO ONLY key (decision 0018).
echo "  Login: admin / ${gpw:-<not unsealed yet: re-run ./platform urls in a minute>}"

step "Prometheus and Alertmanager (no login; bound to 127.0.0.1 only)"
echo "  https://prometheus.localtest.me"
echo "  https://alertmanager.localtest.me"

step "Argo Rollouts dashboard (read-only, no login)"
echo "  https://rollouts.localtest.me"
echo "  Canaries run in the demo copy of prod: ./platform demo canary"

step "orders-gateway"
echo "  https://orders.dev.localtest.me      dev"
echo "  https://orders.staging.localtest.me  staging"
echo "  https://orders.localtest.me          prod (canary via Argo Rollouts)"
