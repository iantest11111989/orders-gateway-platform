#!/usr/bin/env bash
# scripts/images.sh list | save <dir> | load <dir>: an image cache for CI, so a cold `up`
# doesn't depend on every registry answering (they rate-limit and flake:
# ECR Public 429s, ErrImagePull on quay.io and docker.io).
#
#   list        print the images the cache holds (one per line, sorted)
#   save <dir>  pull every image the cluster's pods use by tag (on the Docker
#               host, with retries) and `docker save` each to <dir>/<image>.tar,
#               plus <dir>/images.txt (the sorted list)
#   load <dir>  import every <dir>/*.tar into each worker node, one image at a
#               time. Best effort: an image that isn't there, or won't import,
#               is pulled as usual.
#
# Only images referenced by tag: an image pinned by digest (repo@sha256 or
# repo:tag@sha256) is looked up by its index digest, which a re-saved
# single-platform copy doesn't have, so those are still pulled (4 of 37 on
# 2026-11-25: the app's own image on GHCR and three chart images).
# Exporting from the nodes isn't possible: kind's containerd discards the
# compressed layers once unpacked (discard_unpacked_layers).
# Workers only: the control plane is tainted and runs only DaemonSet and
# kube-system pods, whose images the workers hold too. Uses ctr directly
# rather than `kind load image-archive`, which imports --all-platforms and
# fails on a single-platform archive.
# Runs in the toolbox (needs the Docker socket).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cmd=${1:-}; dir=${2:-}
[ "$cmd" = list ] || { [ -n "$cmd" ] && [ -n "$dir" ]; } || die "usage: scripts/images.sh list | save <dir> | load <dir>"

# Images kind's node image already contains (never pulled). Re-importing
# them fails: their compressed layers were discarded after unpacking.
KIND_PRELOADED='^(registry\.k8s\.io/(kube-(apiserver|controller-manager|scheduler|proxy)|etcd|coredns/coredns):|docker\.io/kindest/)'

workers() { node_containers | grep -v control-plane; }
arch() { case "$(docker exec "$1" uname -m)" in aarch64|arm64) echo arm64 ;; *) echo amd64 ;; esac; }
refs() { docker exec "$1" ctr -n k8s.io images ls -q | grep -v '^sha256:' | sort -u; }

# The images to cache: every image the pods use by tag, minus kind's own.
list_images() {
  kubectl get pods -A -o json |
    jq -r '[.items[].spec | (.containers + (.initContainers // []))[] | .image] | unique | .[] | select(contains("@") | not)' |
    grep -v -E "$KIND_PRELOADED"
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
    # One archive per image, so one that won't import doesn't take the rest
    # with it (shared base layers are stored more than once; that's the cost).
    # Only the Docker host's own platform: with Docker's containerd image
    # store (GitHub's runners), save otherwise writes every platform of a
    # multi-arch image (5.2 GB instead of about 1.2).
    case "$(docker info --format '{{.Architecture}}')" in aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
    while read -r img; do
      docker save --platform "$platform" -o "$dir/$(tr '/:' '__' <<<"$img").tar" "$img"
    done <"$dir/images.txt"
    # docker save writes 0600 files, and the toolbox runs as root: let CI's
    # runner user read them, or actions/cache can't upload them.
    chmod a+rx "$dir"; chmod a+r "$dir"/*
    ok "saved $(grep -c . "$dir/images.txt") images ($(du -cm "$dir"/*.tar | tail -1 | cut -f1) MiB) to $dir"
    [ "$failed" -eq 0 ] || warn "some images were left out (above); they'll be pulled on the next run"
    ;;
  load)
    shopt -s nullglob; tars=("$dir"/*.tar)
    [ "${#tars[@]}" -gt 0 ] || { warn "no image cache in $dir; every image will be pulled"; exit 0; }
    start=$(date +%s)
    # One import loop per worker, in parallel (about half the time).
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
  *) die "usage: scripts/images.sh save|load <dir>" ;;
esac
