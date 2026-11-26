# Host-side helpers shared by ./platform and ./pipeline (POSIX sh; sourced,
# not run). Everything else runs inside the toolbox container, which
# carries every pinned tool. The caller sets REPO_ROOT and cds there first.
# shellcheck shell=sh
TOOLBOX_REPO=ghcr.io/iantest11111989/orders-gateway-platform-toolbox

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

check_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker is not installed. Install Docker Engine (Linux) or Colima / Docker Desktop (macOS), then re-run."
  docker info >/dev/null 2>&1 ||
    die "Docker is installed but not running (or you lack permission to use it). Start Docker and re-run. On macOS with Colima: colima start --cpu 6 --memory 12"
}

# The toolbox tag is a hash of toolbox/, so a change to any pinned version
# gives a new image. CI publishes that tag; if it isn't published yet (for
# example on a branch), build it locally.
toolbox_image() {
  if [ -n "${TOOLBOX_IMAGE:-}" ]; then
    echo "$TOOLBOX_IMAGE"
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum; else sum="shasum -a 256"; fi
  hash=$(cd toolbox && find . -type f | LC_ALL=C sort | xargs cat | $sum | cut -c1-12)
  echo "$TOOLBOX_REPO:sha-$hash"
}

ensure_toolbox() {
  img=$1
  docker image inspect "$img" >/dev/null 2>&1 && return
  if [ -z "${TOOLBOX_IMAGE:-}" ] && docker pull -q "$img" >/dev/null 2>&1; then
    return
  fi
  [ -z "${TOOLBOX_IMAGE:-}" ] || die "toolbox image $img not found"
  echo "Building the toolbox image locally (one time, about a minute)..." >&2
  docker build -q -t "$img" toolbox >/dev/null || die "toolbox build failed"
}

run_toolbox() {
  img=$(toolbox_image)
  ensure_toolbox "$img"
  # Docker can only mount folders it shares with this machine. Colima shares
  # $HOME by default, so a checkout elsewhere (e.g. /tmp) shows up empty.
  docker run --rm -v "$REPO_ROOT":/work --entrypoint test "$img" -f /work/platform ||
    die "Docker can't see this checkout ($REPO_ROOT). With Colima, clone the repo inside your home folder (Colima shares \$HOME by default), or add a mount in ~/.colima/default/colima.yaml."
  tty=""
  if [ -t 0 ] && [ -t 1 ]; then tty="-it"; fi
  # Host network so kind's API server (127.0.0.1) and ports are reachable.
  # The Docker socket lets kind create its node containers. The kubeconfig
  # lives in a named volume, not the repo, so no root-owned or locked files
  # land in your checkout.
  # Create that volume as Compose would (its labels), so a later `docker
  # compose up` adopts it instead of warning that Compose didn't create it.
  docker volume inspect ogp-kube >/dev/null 2>&1 ||
    docker volume create --label com.docker.compose.project=orders-gateway-platform \
      --label com.docker.compose.volume=kube ogp-kube >/dev/null
  # shellcheck disable=SC2086
  ${TOOLBOX_EXEC-exec} docker run --rm $tty \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$REPO_ROOT":/work \
    -v ogp-kube:/root/.kube \
    -w /work \
    -e TOOLBOX_IMAGE="$img" \
    -e REPO_URL="${REPO_URL:-}" \
    -e REVISION="${REVISION:-}" \
    -e PRELOAD_IMAGES="${PRELOAD_IMAGES:-}" \
    -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    -e ARGOCD_OPTS="--port-forward --port-forward-namespace argocd --plaintext" \
    "$img" "$@"
}
