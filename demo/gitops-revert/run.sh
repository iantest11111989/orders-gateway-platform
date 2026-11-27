#!/usr/bin/env bash
# ./platform demo gitops-revert [dev|staging|prod]: a bad config commit (30%
# of requests fail) to the environment's env file, apps/orders-gateway/cd/
# <env>.yaml, on the in-stack Git server Argo CD deploys from. Argo CD syncs
# it (staging and prod at the Sync point), then a `git revert` heals it.
# Prod unless you name another environment.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

BAD_PUSHED='' WORK=''
# If the demo stops after the bad commit and before its revert, revert it:
# never leave the environment failing on purpose.
demo_undo() {
  [ -n "$BAD_PUSHED" ] && [ -n "$WORK" ] || return 0
  warn "reverting the bad commit (the demo stopped early)"
  if git -C "$WORK" -c user.name="orders-gateway demo" -c user.email="demo@localhost" revert --no-edit HEAD >/dev/null &&
    gitauth -C "$WORK" push origin HEAD:main >/dev/null 2>&1 &&
    { [ "$ENV" = dev ] || sync_app "$APP" demo >/dev/null; }; then
    ok "reverted and synced: $ENV is back to what Git had before the demo"
  else
    warn "the revert didn't go through: $ENV may still fail 30% of requests."
    warn "Fix: remove config.faultErrorRate from apps/orders-gateway/cd/$ENV.yaml in the in-cluster Git, then Sync $APP"
  fi
}

# Pushes the clone's HEAD to main; staging and prod then wait at the Sync point.
push_and_sync() {
  run gitauth -C "$WORK" push origin HEAD:main
  ok "pushed $(git -C "$WORK" log -1 --format='%h %s')"
  if [ "$ENV" = dev ]; then
    note "dev has auto-sync on: Argo CD applies it by itself"
  else
    run kubectl -n argocd annotate applications.argoproj.io "$APP" argocd.argoproj.io/refresh=normal --overwrite
    sleep 5
    run kubectl -n argocd get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.status}{"\n"}'
    note "OutOfSync: Git has the commit, $ENV doesn't. Auto-sync is off here, so nothing changes until someone presses Sync"
    sync_app "$APP" demo
  fi
}

demo_gitops_revert() {
  step "Demo: GitOps revert in $ENV ($URL)"
  echo "  A bad config commit (FAULT_ERROR_RATE 0.3: 30% of /work and /echo return 500)"
  echo "  lands in apps/orders-gateway/cd/$ENV.yaml on the in-stack Git server; Argo CD"
  echo "  syncs it and the errors show up. Then \`git revert\` and Argo CD heals it."
  echo "  Nothing is changed by hand in the cluster. Takes about 5 minutes."
  local repo base remote
  repo=$(get kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}')
  base=$(get kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.targetRevision}')
  note "the Git repo and branch Argo CD deploys from (the in-stack Git server)"
  [ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from $repo, not the in-stack Git server: run ./platform up, which points it back at this checkout"
  [ "$base" = main ] || die "Argo CD deploys from $base, not main: run ./platform up"
  instack_remote; remote=$INSTACK_REMOTE
  WORK=$(mktemp -d); GIT_WORK=$WORK
  wait_healthy 600

  step "Cloning what Argo CD deploys from"
  run gitauth clone --depth 5 --branch main "$remote" "$WORK"
  start_load
  where_to_watch
  check "Argo CD, $APP" "http://localhost:8081/applications/argocd/$APP" \
    "the sync status names the commit it deployed: watch it change to the bad commit, then to the revert" \
    "History and rollback lists each sync with its Git revision: Git is the record of what ran"
  check "Grafana, orders-gateway dashboard (environment $NS)" "$(dash_url orders-gateway "$NS")" \
    "/work and /echo: share failing with 5xx: climbs toward 30% after the bad commit, back to 0 after the revert" \
    "Firing SLO alerts: the availability alert may go pending while the errors last"

  step "Committing a bad config change to apps/orders-gateway/cd/$ENV.yaml"
  run yq -i '.config.faultErrorRate = 0.3' "$WORK/apps/orders-gateway/cd/$ENV.yaml"
  note "the chart turns config.faultErrorRate into the app's FAULT_ERROR_RATE env var (an app setting, no code change)"
  run git -C "$WORK" --no-pager diff
  run git -C "$WORK" -c user.name="orders-gateway demo" -c user.email="demo@localhost" \
    commit -am "demo: FAULT_ERROR_RATE 0.3 in $ENV (30% of requests fail)"
  BAD_PUSHED=1
  push_and_sync
  narrate_git "$(git -C "$WORK" rev-parse HEAD)" 60 400
  bad=$(error_ratio)
  run curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' "$URL/echo"
  note "some requests now answer 500 (30% of /work and /echo)"
  check "Grafana → Explore → Loki: the failing requests" \
    "$(loki_url "{namespace=\"$NS\", app=\"orders-gateway\"} | json | level=\"error\"")" \
    "500s on /work and /echo, each with duration_ms near 0: they fail before doing any work, which points at config, not load" \
    "query: {namespace=\"$NS\", app=\"orders-gateway\"} | json | level=\"error\""

  step "Reverting it in Git"
  run git -C "$WORK" -c user.name="orders-gateway demo" -c user.email="demo@localhost" revert --no-edit HEAD
  run git -C "$WORK" --no-pager show --format='%h %s' HEAD
  push_and_sync
  BAD_PUSHED=''
  narrate_git "$(git -C "$WORK" rev-parse HEAD)" 70 400
  good=$(error_ratio)
  k6_summary

  [ "${bad%\%}" -ge 10 ] 2>/dev/null || die "the bad commit didn't show up as errors (5xx share $bad)"
  [ "${good%\%}" -le 1 ] 2>/dev/null || die "errors didn't stop after the revert (5xx share $good)"
  ok "bad commit: ${bad} of requests failed; after the revert: ${good}. Git was the only thing changed."
}

demo_gitops_revert
finish
