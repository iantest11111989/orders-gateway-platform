#!/usr/bin/env bash
# scripts/git-sync.sh: the in-stack Git server (decision 0029). Installs it if
# needed, then pushes a snapshot of this checkout's working tree to its
# platform.git main, which Argo CD syncs from by default. The cluster runs the
# checkout it was started from, not a copy on GitHub.
#
# - Snapshot = the working tree as it is (committed or not), minus what
#   .gitignore excludes. Works without a .git (a tarball).
# - Each snapshot's parent is the previous in-stack main, so the history is
#   real and `git revert` works there; nothing is pushed if nothing changed.
# - Only the bootstrap's key can push (anonymous clones are read-only). The
#   key lives in the cluster (Secret git/git-admin), next to the repositories
#   it guards: soft-serve takes its admin key only when it first creates its
#   database, so key and data must live and die together.
# Called by up.sh (and `./platform ship`). Runs in the toolbox.
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
  ssh-keygen -q -t ed25519 -N '' -C orders-gateway-platform-bootstrap -f "$KEY"
  kubectl -n git create secret generic git-admin \
    --from-file=private_key="$KEY" --from-file=authorized_key="$KEY.pub" >/dev/null
fi
chmod 600 "$KEY"
kubectl apply -k "$ROOT/gitops/manifests/git-server" >/dev/null
kubectl -n git rollout status deploy/soft-serve --timeout=180s >/dev/null
ok "soft-serve ready ($IN_CLUSTER_URL)"

# Reach its SSH port from here through the API server (no host port needed).
pf_log="$tmp/pf.log"
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
  # Say where the snapshot came from, if the checkout is a Git repository.
  origin="a checkout without Git history"
  if head=$(git -c safe.directory='*' -C "$ROOT" log -1 --format='%h %s' 2>/dev/null); then
    origin="local HEAD $head"
    [ -z "$(git -c safe.directory='*' -C "$ROOT" status --porcelain 2>/dev/null)" ] || origin="$origin, plus uncommitted changes"
  fi
  commit=$(GIT_AUTHOR_NAME="orders-gateway-platform bootstrap" GIT_AUTHOR_EMAIL="bootstrap@localhost" \
    GIT_COMMITTER_NAME="orders-gateway-platform bootstrap" GIT_COMMITTER_EMAIL="bootstrap@localhost" \
    g commit-tree "$tree" ${parent:+-p "$parent"} -m "Snapshot of the checkout ($origin)")
  g push -q "$remote" "$commit:refs/heads/main"
  ok "pushed ${commit:0:12}: snapshot of $origin"
  echo "$commit" >"$tmp/rev"
fi

# Argo CD polls every 3 minutes; ask it to look now.
for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null); do
  kubectl -n argocd annotate "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done
