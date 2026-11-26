#!/usr/bin/env bash
# scripts/git-sync.sh: the in-stack Git server. Installs it if
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
  # A server whose data outlived its key would refuse every push (soft-serve
  # takes its admin key only when it first creates its database). The data is
  # only snapshots of this checkout, which the push below recreates: reset it.
  if kubectl -n git get pvc soft-serve >/dev/null 2>&1; then
    warn "the Git server's data is there but its admin key is gone; resetting the server (it only holds snapshots of this checkout)"
    kubectl -n git delete deploy soft-serve --ignore-not-found --wait=true >/dev/null
    kubectl -n git delete pvc soft-serve --wait=true >/dev/null
  fi
  ssh-keygen -q -t ed25519 -N '' -C orders-gateway-platform-bootstrap -f "$KEY"
  kubectl -n git create secret generic git-admin \
    --from-file=private_key="$KEY" --from-file=authorized_key="$KEY.pub" >/dev/null
fi
chmod 600 "$KEY"
kubectl apply -k "$ROOT/system/git-server" >/dev/null
kubectl -n git rollout status deploy/soft-serve --timeout=180s >/dev/null
ok "soft-serve ready ($IN_CLUSTER_URL)"

# Reach its SSH port from here through the API server (no host port needed).
pf_log="$tmp/pf.log"
# Create the log first: the backgrounded redirect creates it only once the
# child runs, and a sed that gets there first fails (and set -e stops us).
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

git init -q "$tmp/g"
g() { git -c safe.directory='*' --git-dir="$tmp/g/.git" --work-tree="$ROOT" "$@"; }
# The checkout's own Git, if it has one (a zip download doesn't).
c() { git -c safe.directory='*' -C "$ROOT" "$@"; }
has_history=false
c rev-parse --git-dir >/dev/null 2>&1 && has_history=true

# Chart versions are Git tags <app>-chart-<version>. staging and prod run the
# chart at the tag their cd/<app>/<env>.yaml pins (chartVersion); dev runs
# helm/<app>/ as it is. The in-stack server gets the checkout's chart tags
# and a tag for each chart's current version. Tags there are never moved or
# deleted: a version means one chart.
step "Chart versions (tags <app>-chart-<version>)"
# A new server has no platform.git yet (the first push creates it): no tags.
{ g ls-remote --tags "$remote" '*-chart-*' 2>/dev/null || true; } |
  sed -n 's|.*refs/tags/\([^^]*\)$|\1|p' | sort -u >"$tmp/tags.stack"
: >"$tmp/tags.local"
$has_history && c tag -l '*-chart-*' | sort -u >"$tmp/tags.local"
: >"$tmp/tags.new" # tags to create on the snapshot
for chart in "$ROOT"/helm/*/Chart.yaml; do
  app=$(basename "$(dirname "$chart")")
  v=$(yq '.version' "$chart")
  echo "$app-chart-$v" >>"$tmp/tags.new"
done
for f in "$ROOT"/cd/*/staging.yaml "$ROOT"/cd/*/prod.yaml; do
  [ -f "$f" ] || continue
  app=$(basename "$(dirname "$f")")
  v=$(yq '.chartVersion // ""' "$f")
  [ -n "$v" ] || die "${f#"$ROOT"/} has no chartVersion: staging and prod run a released chart (tag $app-chart-<version>)"
  t="$app-chart-$v"
  grep -qxF "$t" "$tmp/tags.stack" "$tmp/tags.local" "$tmp/tags.new" && continue
  if $has_history; then
    die "${f#"$ROOT"/} pins chart $v, but there's no tag $t here or on the in-stack server. Fetch the tags (git fetch --tags) or release it (./pipeline ci $app --chart $v)."
  fi
  warn "${f#"$ROOT"/} pins chart $v and this checkout has no Git history to find tag $t in; tagging this snapshot as $t, so $(basename "$f" .yaml) runs the chart as it is here"
  echo "$t" >>"$tmp/tags.new"
done

step "Snapshot of this checkout → in-stack main"
hand_over_released_apps
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
  g push -q "$remote" "$commit:refs/heads/main" ||
    die "push to the in-stack Git server refused; if its admin key changed, reset it: kubectl -n git delete secret git-admin, then run ./platform up again"
  ok "pushed ${commit:0:12}: snapshot of $origin"
  echo "$commit" >"$tmp/rev"
fi
rev=$(cat "$tmp/rev")

# The checkout's chart tags the server lacks (with the commits they point at).
for t in $(comm -23 "$tmp/tags.local" "$tmp/tags.stack"); do
  c push -q "$remote" "refs/tags/$t:refs/tags/$t" ||
    die "couldn't push tag $t to the in-stack Git server (a shallow clone? git fetch --unshallow --tags)"
  echo "$t" >>"$tmp/tags.stack"
  ok "$t (from this checkout)"
done
# A version nobody tagged yet: tag the snapshot. A version already tagged:
# only check that the chart is still the same.
sort -u "$tmp/tags.new" | while read -r t; do
  app=${t%-chart-*}
  if grep -qxF "$t" "$tmp/tags.stack"; then
    g fetch -q "$remote" "refs/tags/$t:refs/tags/$t" 2>/dev/null || true
    if [ "$(g rev-parse -q --verify "$t^{commit}:helm/$app" 2>/dev/null)" != "$(g rev-parse "$rev:helm/$app")" ]; then
      warn "helm/$app has changed since $t: dev runs it as it is; staging and prod keep their pinned version. Release it with a new version: ./pipeline ci $app --chart <version>"
    fi
  else
    g push -q "$remote" "$rev:refs/tags/$t" || die "couldn't create tag $t on the in-stack Git server"
    ok "$t (this snapshot)"
  fi
done

# Argo CD polls every 3 minutes; ask it to look now.
for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null); do
  kubectl -n argocd annotate "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done
