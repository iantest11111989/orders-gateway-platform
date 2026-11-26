#!/usr/bin/env bash
# scripts/promotion-gate.sh <app> <env>: may <app> be promoted INTO <env>?
# `./pipeline cd <app> <env> --version X` asks this before it changes
# cd/<app>/<env>.yaml. Promotion goes dev → staging → prod, so the gate looks
# at the environment the version comes from (staging ← dev, prod ← staging):
#   1. its Argo CD Application, <app>-<previous env>, is Synced and Healthy;
#   2. no alert is firing there for this app (ALERTS with namespace=<previous
#      env> and service=<app>: the app's SLO and delivery alerts carry both).
# dev has no gate. Whether the version itself already ran in the previous env
# is ./pipeline's check (the env files' Git history), not this one.
# Exit 0: open. Exit 1: refused, with the reasons on stderr. Prometheus not
# answering also refuses: a gate that can't see is closed.
# Runs in the toolbox; Prometheus through the API server's service proxy.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 2 ] || die "usage: promotion-gate.sh <app> <dev|staging|prod>"
app=$1 env=$2
case "$env" in
  dev) ok "dev has no promotion gate"; exit 0 ;;
  staging) from=dev ;;
  prod) from=staging ;;
  *) die "env must be dev, staging or prod: '$env'" ;;
esac

step "Promotion gate: $app into $env (checks $app in $from)"
refused=0
no() { fail "$*" >&2; refused=$((refused + 1)); }

# 1. Argo CD: the previous environment runs what Git says, and it's healthy.
name="$app-$from"
if st=$(kubectl -n argocd get applications.argoproj.io "$name" \
    -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null); then
  read -r sync health <<<"$st"
  if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then ok "Argo CD: $name Synced and Healthy"
  else no "Argo CD: $name is ${sync:-Unknown}, ${health:-Unknown} (want Synced, Healthy): fix $from first"; fi
else
  no "Argo CD: no Application $name (is $app deployed to $from?)"
fi

# 2. Alerts firing for this app in the previous environment.
q="ALERTS{alertstate=\"firing\",namespace=\"$from\",service=\"$app\"}"
url="/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$q" '$q|@uri')"
if res=$(kubectl get --raw "$url" 2>/dev/null) && [ "$(jq -r '.status' <<<"$res")" = success ]; then
  firing=$(jq -r '[.data.result[].metric.alertname] | unique | join(", ")' <<<"$res")
  if [ -z "$firing" ]; then ok "Alerts: none firing for $app in $from"
  else no "Alerts firing for $app in $from: $firing (see ./platform urls → Alertmanager)"; fi
else
  no "Prometheus didn't answer, so the alerts can't be checked: the gate stays closed (./pipeline cd --force skips it)"
fi

[ "$refused" -eq 0 ] || die "promotion of $app into $env refused ($refused check(s) above)"
ok "gate open: $app may go to $env"
