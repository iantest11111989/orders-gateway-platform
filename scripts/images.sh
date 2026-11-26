#!/usr/bin/env bash
# scripts/images.sh list | save <dir> | load <dir>: an image cache for CI, so
# a cold `up` doesn't fail when a registry rate-limits or flakes (it's for
# reliability, not speed). load imports into the workers, best effort.
# Gotchas:
# - Digest-pinned images are still pulled: a re-saved single-platform copy
#   lacks the index digest.
# - Images can't be exported from the nodes: kind's containerd discards
#   compressed layers (discard_unpacked_layers).
# - ctr, not `kind load image-archive`, which fails on single-platform archives.
# Runs in the toolbox (needs the Docker socket).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cmd=${1:-}; dir=${2:-}
[ "$cmd" = list ] || { [ -n "$cmd" ] && [ -n "$dir" ]; } || die "usage: scripts/images.sh list | save <dir> | load <dir>"

# Preloaded in kind's node image; re-importing them fails (layers discarded).
KIND_PRELOADED='^(registry\.k8s\.io/(kube-(apiserver|controller-manager|scheduler|proxy)|etcd|coredns/coredns):|docker\.io/kindest/)'

workers() { node_containers | grep -v control-plane; }
arch() { case "$(docker exec "$1" uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac; }
refs() { docker exec "$1" ctr -n k8s.io images ls -q | grep -v '^sha256:' | sort -u; }

# Tagged images in use, minus kind's own and the in-stack registry's (not
# pullable from the Docker host).
list_images() {
  kubectl get pods -A -o json |
    jq -r '[.items[].spec | (.containers + (.initContainers // []))[] | .image] | unique | .[] | select(contains("@") | not)' |
    grep -v -E "$KIND_PRELOADED" | grep -v '^localhost:30500/' || true
}

[ "$cmd" = list ] && { list_images; exit 0; }

case "$cmd" in
  save)
    mkdir -p "$dir"; rm -f "$dir"/*.tar "$dir/images.txt"
    list_images >"$dir/images.txt"
    [ -s "$dir/images.txt" ] || die "no pods with tagged images; run this after ./platform up"
    failed=0
    while read -r img; do
      for attempt in 1 2 3; do
        docker pull -q "$img" >/dev/null 2>&1 && continue 2
        sleep $((attempt * 10))
      done
      warn "couldn't pull $img; leaving it out of the cache"; failed=1
      sed -i "\|^$img\$|d" "$dir/images.txt"
    done < <(cat "$dir/images.txt")
    # One archive per image so one bad import doesn't break the rest. Only the
    # host platform, or the containerd image store saves every arch (5 GB vs 1).
    case "$(docker info --format '{{.Architecture}}')" in aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
    while read -r img; do
      docker save --platform "$platform" -o "$dir/$(tr '/:' '__' <<<"$img").tar" "$img"
    done <"$dir/images.txt"
    # docker save writes 0600 as root; actions/cache needs to read them.
    chmod a+rx "$dir"; chmod a+r "$dir"/*
    ok "saved $(grep -c . "$dir/images.txt") images ($(du -cm "$dir"/*.tar | tail -1 | cut -f1) MiB) to $dir"
    [ "$failed" -eq 0 ] || warn "some images were left out (above); they'll be pulled on the next run"
    ;;
  load)
    shopt -s nullglob; tars=("$dir"/*.tar)
    [ "${#tars[@]}" -gt 0 ] || { warn "no image cache in $dir; every image will be pulled"; exit 0; }
    start=$(date +%s)
    import_into() { # import_into <node>
      local n=$1 a loaded=0 skipped=0 t
      a=$(arch "$n")
      for t in "${tars[@]}"; do
        if docker exec -i "$n" ctr -n k8s.io images import --platform "linux/$a" \
            --snapshotter overlayfs - <"$t" >/dev/null 2>&1; then loaded=$((loaded + 1))
        else skipped=$((skipped + 1)); fi
      done
      if [ "$skipped" -eq 0 ]; then ok "$n: imported all ${#tars[@]} images"
      else warn "$n: imported $loaded of ${#tars[@]} images; $skipped will be pulled instead"; fi
    }
    pids=()
    for n in $(workers); do import_into "$n" & pids+=("$!"); done
    wait "${pids[@]}"
    ok "image cache loaded in $(( $(date +%s) - start ))s"
    ;;
  *) die "usage: scripts/images.sh list | save <dir> | load <dir>" ;;
esac
