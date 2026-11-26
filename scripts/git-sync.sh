#!/usr/bin/env bash
# scripts/git-sync.sh: installs the in-stack Git server if needed and pushes a
# snapshot of this working tree (committed or not, minus .gitignore) to its
# main, which Argo CD syncs from. Each snapshot's parent is the previous main,
# so `git revert` works there. Only the bootstrap key (Secret git/git-admin)
# can push. Called by up.sh; runs in the toolbox.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IN_CLUSTER_URL=http://git.git.svc.cluster.local:23232/platform.git

step "In-stack Git server (soft-serve, namespace git)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
KEY="$tmp/id_ed25519"
kubectl create namespace git --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if kubectl -n git get secret git-admin >/dev/null 2>&1; then
  kubectl -n git get secret git-admin -o jsonpath='{.data.private_key}' | base64 -d >"$KEY"
else
  # soft-serve takes its admin key only when it first creates its database, so
  # data without its key refuses every push. It only holds snapshots: reset it.
  if kubectl -n git get pvc soft-serve >/dev/null 2>&1; then
    warn "the Git server's data is there but its admin key is gone; resetting the server (it only holds snapshots of this checkout)"
    kubectl -n git delete deploy soft-serve --ignore-not-found --wait=true >/dev/null
    kubectl -n git delete pvc soft-serve --wait=true >/dev/null
  fi
  ssh-keygen -q -t ed25519 -N '' -C platform-demo-bootstrap -f "$KEY"
  kubectl -n git create secret generic git-admin \
    --from-file=private_key="$KEY" --from-file=authorized_key="$KEY.pub" >/dev/null
fi
chmod 600 "$KEY"
kubectl apply -k "$ROOT/system/git-server" >/dev/null
kubectl -n git rollout status deploy/soft-serve --timeout=180s >/dev/null
ok "soft-serve ready ($IN_CLUSTER_URL)"

pf_log="$tmp/pf.log"
# Create the log first, or a sed that runs before the child does fails (set -e).
: >"$pf_log"
kubectl -n git port-forward svc/git :23231 >"$pf_log" 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true; rm -rf "$tmp"' EXIT
port=''
for _ in $(seq 1 30); do
  port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$pf_log" | head -1)
  [ -n "$port" ] && break
  sleep 0.5
done
[ -n "$port" ] || die "couldn't port-forward to the Git server: $(cat "$pf_log")"
remote="ssh://127.0.0.1:$port/platform.git"
export GIT_SSH_COMMAND="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

step "Snapshot of this checkout → in-stack main"
hand_over_app_applications
git init -q "$tmp/g"
g() { git -c safe.directory='*' --git-dir="$tmp/g/.git" --work-tree="$ROOT" "$@"; }
parent=''
if g fetch -q "$remote" main 2>/dev/null; then parent=$(g rev-parse FETCH_HEAD); fi
g add -A
tree=$(g write-tree)
if [ -n "$parent" ] && [ "$tree" = "$(g rev-parse "$parent^{tree}")" ]; then
  ok "unchanged: in-stack main is already this checkout (${parent:0:12})"
  echo "$parent" >"$tmp/rev"
else
  origin="a checkout without Git history"
  if head=$(git -c safe.directory='*' -C "$ROOT" log -1 --format='%h %s' 2>/dev/null); then
    origin="local HEAD $head"
    [ -z "$(git -c safe.directory='*' -C "$ROOT" status --porcelain 2>/dev/null)" ] || origin="$origin, plus uncommitted changes"
  fi
  commit=$(GIT_AUTHOR_NAME="platform-demo bootstrap" GIT_AUTHOR_EMAIL="bootstrap@localhost" \
    GIT_COMMITTER_NAME="platform-demo bootstrap" GIT_COMMITTER_EMAIL="bootstrap@localhost" \
    g commit-tree "$tree" ${parent:+-p "$parent"} -m "Snapshot of the checkout ($origin)")
  showcmd "git add -A && git write-tree   # git --git-dir=<temp> --work-tree=<checkout>: your own .git isn't touched"
  showcmd "git commit-tree $tree${parent:+ -p ${parent:0:12}} -m 'Snapshot of the checkout ($origin)'"
  showcmd "git push $remote ${commit:0:12}:refs/heads/main"
  g push -q "$remote" "$commit:refs/heads/main" ||
    die "push to the in-stack Git server refused; if its admin key changed, reset it: kubectl -n git delete secret git-admin, then run ./platform up again"
  ok "pushed ${commit:0:12}: snapshot of $origin"
  echo "$commit" >"$tmp/rev"
fi

# Argo CD polls every 3 minutes; ask it to look now.
for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null); do
  kubectl -n argocd annotate "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done
