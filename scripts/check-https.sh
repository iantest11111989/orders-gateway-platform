#!/usr/bin/env bash
# Checks the HTTPS entry point end to end: every platform hostname answers
# over HTTPS with a certificate from the demo CA, and plain HTTP redirects.
# Runs in the toolbox (./platform shell scripts/check-https.sh); CI runs it
# after ./platform up. Part of ./platform verify later.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ca=$(mktemp)
trap 'rm -f "$ca"' EXIT
kubectl -n cert-manager get secret ogp-demo-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$ca"
[ -s "$ca" ] || die "demo CA secret cert-manager/ogp-demo-ca not found"

step "HTTPS through Envoy Gateway (127.0.0.1:443, demo CA)"
status=0
# host[/path]  expected status (Grafana and Prometheus redirect to their start pages)
while read -r host want; do
  got=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$ca" --max-time 10 "https://$host" 2>&1) || true
  if [ "$got" = "$want" ]; then ok "https://$host -> $got"; else fail "https://$host -> $got (want $want)"; status=1; fi
done <<'HOSTS'
argocd.localtest.me/ 200
grafana.localtest.me/ 302
prometheus.localtest.me/ 302
alertmanager.localtest.me/ 200
orders.dev.localtest.me/healthz 200
orders.staging.localtest.me/healthz 200
orders.localtest.me/healthz 200
HOSTS

got=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 http://grafana.localtest.me/login 2>&1) || true
if [ "$got" = "301 https://grafana.localtest.me/login" ]; then ok "http:// redirects to https:// (301)"; else fail "http://grafana.localtest.me/login -> $got (want 301 to https)"; status=1; fi
exit "$status"
