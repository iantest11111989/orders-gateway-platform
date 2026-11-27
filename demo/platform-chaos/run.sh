#!/usr/bin/env bash
# ./platform demo platform-chaos [--keep]: in a copy of prod under load,
# delete the platform's own pods one at a time (Traefik, CoreDNS, the Argo CD
# repo server and application controller, Prometheus, the Kyverno admission
# controller) and show each come back, and what the app needed from it.
# Fails if fewer than 99.5% of k6's requests meet the SLO.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

# --- helpers -----------------------------------------------------------------

# pods <ns> <selector>: "uid name ready node", one line per pod that isn't
# being deleted.
pods() {
  kubectl -n "$1" get pods -l "$2" -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null) |
      "\(.metadata.uid) \(.metadata.name) \(([.status.conditions[]? | select(.type == "Ready") | .status][0]) // "False") \(.spec.nodeName // "-")"'
}

# probe: one request through Traefik to the demo copy, with its status and time.
probe() {
  local out
  show "curl -s -o /dev/null -w '%{http_code} %{time_total}s' $URL/version"
  out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' --max-time 5 "$URL/version" 2>&1 || true)
  printf '%s\n' "$out" | indent
}

# kill_one <ns> <selector> <component> <what the app needs from it>
# Deletes the first pod matching <selector>, waits until as many Ready pods
# as before are back (none of them the deleted one), and shows them.
kill_one() {
  local ns=$1 sel=$2 what=$3 needs=$4 before want victim uid deadline last='' n
  step "Killing $what"
  before=$(pods "$ns" "$sel")
  want=$(awk '$3 == "True"' <<<"$before" | grep -c . || true)
  [ "$want" -gt 0 ] || die "no ready $what pod (namespace $ns, -l $sel)"
  run kubectl -n "$ns" get pods -l "$sel" -o wide
  read -r uid victim _ <<<"$(head -1 <<<"$before")"
  run kubectl -n "$ns" delete pod "$victim" --wait=false
  note "a plain delete, as a crash or an OOM kill would be: no PodDisruptionBudget is asked"
  ok "deleted $victim"

  note "every 2 s: kubectl -n $ns get pods -l $sel (count the Ready ones that aren't $victim) until $want are back"
  deadline=$(( $(date +%s) + 300 ))
  while :; do
    n=$(pods "$ns" "$sel" | awk -v u="$uid" '$1 != u && $3 == "True"' | grep -c . || true)
    [ "$n" != "$last" ] && { printf '  %s  ready: %s of %s\n' "$(date +%H:%M:%S)" "$n" "$want" >&2; last=$n; }
    [ "$n" -ge "$want" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || die "only $n of $want $what pods ready after 300 s"
    sleep 2
  done
  run kubectl -n "$ns" get pods -l "$sel" -o wide
  ok "$what is back"
  note "what the app needed from it: $needs"
  probe
}

demo_platform_chaos() {
  step "Demo: platform components killed under load, in a copy of prod"
  echo "  The goal: stay available and reasonably fast while individual pods"
  echo "  and platform components are killed. k6 sends traffic through Traefik"
  echo "  to a copy of prod the whole time; one platform pod at a time is"
  echo "  deleted and comes back. The app's own pods are the chaos demo."
  ensure_app orders-gateway-prod v1
  wait_healthy v1 600
  start_load
  where_to_watch
  probe

  kill_one traefik app.kubernetes.io/name=traefik "a Traefik pod" \
    "every request. There are 2 replicas, one per zone, behind the NodePort; while one restarts, the other carries all the traffic"

  kill_one kube-system k8s-app=kube-dns "a CoreDNS pod" \
    "nothing per request: Traefik routes to pod IPs from the Kubernetes API, not DNS. In-cluster name lookups go to the second CoreDNS replica meanwhile"

  kill_one argocd app.kubernetes.io/name=argocd-repo-server "the Argo CD repo server" \
    "nothing at runtime. It renders charts from Git; while it's gone Argo CD can't render a new sync, so a deploy would wait. The running pods are untouched"
  run kubectl -n argocd get applications.argoproj.io "$APP"
  note "still Synced/Healthy: the app never depended on it"

  kill_one argocd app.kubernetes.io/name=argocd-application-controller "the Argo CD application controller (argocd-application-controller-0)" \
    "nothing at runtime. It syncs and self-heals Applications; while it's gone, drift isn't corrected. When it's back, it re-reads every Application"
  run kubectl -n argocd get applications.argoproj.io "$APP"

  kill_one monitoring app.kubernetes.io/name=prometheus "Prometheus (prometheus-kube-prometheus-stack-prometheus-0)" \
    "nothing per request. Metrics and alert rules pause: a short gap in the graphs, and alerts are evaluated again when it's back. This demo's SLO check is k6's own count, so it doesn't depend on Prometheus"

  kill_one kyverno app.kubernetes.io/component=admission-controller "the Kyverno admission controller" \
    "nothing for running pods. It admits new pods (signed images, no :latest). It has 1 replica, so while it restarts, which way each webhook fails is its failurePolicy, below"
  run kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
    -o 'jsonpath={range .webhooks[*]}{.failurePolicy}{"\t"}{.name}{"\n"}{end}'
  note "Fail: requests that webhook checks are refused until Kyverno is back. Ignore: they're admitted unchecked meanwhile"

  sleep 10
  k6_summary
  if awk -v p="${SLO_PCT:-0}" 'BEGIN { exit !(p >= 99.5) }'; then
    ok "the service stayed up: ${SLO_PCT}% of requests met the SLO (>= 99.5%)"
  else
    die "requests failed while platform pods were killed: only ${SLO_PCT:-?}% met the SLO (want >= 99.5%)"
  fi
}

demo_platform_chaos
finish
