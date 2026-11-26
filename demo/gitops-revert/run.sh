#!/usr/bin/env bash
# ./platform demo gitops-revert [--keep]: a bad config commit (30% of requests
# fail) on a demo branch that a copy of dev follows; Argo CD syncs it, then a
# `git revert` heals it. It pushes to the in-stack Git server.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

demo_gitops_revert() {
  step "Demo: GitOps revert, in a copy of dev that follows a demo branch"
  echo "  A bad config commit (FAULT_ERROR_RATE 0.3: 30% of /work and /echo return 500)"
  echo "  lands on a demo branch; Argo CD syncs it and the errors show up. Then"
  echo "  \`git revert\` and Argo CD heals it. Nothing is changed by hand in the"
  echo "  cluster. Takes about 5 minutes."
  local repo base branch work remote
  repo=$(get kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.repoURL}')
  base=$(get kubectl -n argocd get applications.argoproj.io root -o jsonpath='{.spec.source.targetRevision}')
  note "the Git repo and branch Argo CD deploys from (the in-stack Git server)"
  [ "$repo" = "$IN_STACK" ] || die "Argo CD syncs from $repo, not the in-stack Git server: run ./platform up, which points it back at this checkout"
  instack_remote; remote=$INSTACK_REMOTE
  branch="demo/gitops-revert-$(date -u +%Y%m%d-%H%M%S)"
  work=$(mktemp -d); GIT_WORK=$work
  DEMO_BRANCH=$branch DEMO_REPO=$remote

  step "Creating $branch in $repo (from $base)"
  run gitauth clone --depth 5 --branch "$base" "$remote" "$work"
  run git -C "$work" switch -c "$branch"
  run gitauth -C "$work" push origin "$branch"
  ok "pushed $branch"

  delete_app
  DEMO_REVISION=$branch create_app orders-gateway-dev v1 replicas=3
  wait_healthy v1 600
  start_load
  where_to_watch
  narrate_git "$(git -C "$work" rev-parse HEAD)" 30 300

  step "Committing a bad config change to $branch"
  run yq -i '.config.faultErrorRate = 0.3' "$work/cd/orders-gateway/dev.yaml"
  note "the chart turns config.faultErrorRate into the app's FAULT_ERROR_RATE env var (an app setting, no code change)"
  run git -C "$work" --no-pager diff
  run git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" \
    commit -am "demo: FAULT_ERROR_RATE 0.3 in dev (30% of requests fail)"
  run gitauth -C "$work" push origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 60 400
  bad=$(error_ratio)
  run curl -s -o /dev/null -w '%{http_code}\n' -X POST -d '{}' "$URL/echo"
  note "some requests now answer 500 (30% of /work and /echo)"

  step "Reverting it in Git"
  run git -C "$work" -c user.name="orders-gateway demo" -c user.email="demo@localhost" revert --no-edit HEAD
  run git -C "$work" --no-pager show --format='%h %s' HEAD
  run gitauth -C "$work" push origin "$branch"
  ok "pushed $(git -C "$work" log -1 --format='%h %s')"
  narrate_git "$(git -C "$work" rev-parse HEAD)" 70 400
  good=$(error_ratio)
  k6_summary

  [ "${bad%\%}" -ge 10 ] 2>/dev/null || die "the bad commit didn't show up as errors (5xx share $bad)"
  [ "${good%\%}" -le 1 ] 2>/dev/null || die "errors didn't stop after the revert (5xx share $good)"
  ok "bad commit: ${bad} of requests failed; after the revert: ${good}. Git was the only thing changed."
}

demo_gitops_revert
finish
