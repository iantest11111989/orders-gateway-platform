#!/usr/bin/env bash
# scripts/registry.sh: the in-stack registry (system/registry/), where each
# app's published versions live: image <app>:<version> and Helm chart
# charts/<app> <version> (OCI). Pods use the images as
# localhost:30500/<app>:<tag>; Argo CD reads the charts from
# registry.registry.svc.cluster.local:5000/charts.
#
#   install                    apply system/registry and wait for it
#   published <app> <version>  exit 0 if the image or the chart exists
#   digest <app> <tag>         print the image's digest (sha256:...)
#   push-image <app> <tag>     push the local image localhost:30500/<app>:<tag>
#   publish <app> <version>    push image <app>:<version> and the chart
#                              helm/<app> as <version>; refuses a version
#                              that's already published (never overwritten)
#   seed                       publish every version cd/<app>/*.yaml pins
#                              that the registry lacks, built from this
#                              checkout (a fresh cluster's first versions)
#
# Pushes go through `kubectl port-forward` to 127.0.0.1, which Docker and
# Helm reach over plain HTTP. Called by up.sh and ./pipeline; runs in the
# toolbox (needs the Docker socket).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NODE_REGISTRY=localhost:30500

semver() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; }
check_app() {
  [[ $1 =~ ^[a-z0-9-]+$ ]] && [ -d "$ROOT/helm/$1" ] && [ -d "$ROOT/apps/$1" ] || die "unknown app '$1'"
}

tmp=$(mktemp -d)
pf=''
trap '[ -z "$pf" ] || kill "$pf" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# Sets REG=127.0.0.1:<port>, forwarded to the registry's Service.
forward() {
  [ -n "$pf" ] && return 0
  kubectl -n registry get svc registry >/dev/null 2>&1 ||
    die "no in-stack registry (namespace registry): start the cluster with ./platform up"
  : >"$tmp/pf.log"
  kubectl -n registry port-forward svc/registry :5000 >"$tmp/pf.log" 2>&1 &
  pf=$!
  local port=''
  for _ in $(seq 1 30); do
    port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) .*/\1/p' "$tmp/pf.log" | head -1)
    [ -n "$port" ] && break
    sleep 0.5
  done
  [ -n "$port" ] || die "couldn't port-forward to the registry: $(cat "$tmp/pf.log")"
  REG=127.0.0.1:$port
  for _ in $(seq 1 20); do
    curl -fsS -o /dev/null "http://$REG/v2/" && return 0
    sleep 0.5
  done
  die "the registry doesn't answer on $REG"
}

# HEAD of a manifest: prints the digest, or nothing if it doesn't exist.
manifest_digest() { # manifest_digest <repository> <reference>
  curl -fsS -I \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://$REG/v2/$1/manifests/$2" 2>/dev/null |
    tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p'
}

published() { # published <app> <version>
  forward
  [ -n "$(manifest_digest "$1" "$2")" ] || [ -n "$(manifest_digest "charts/$1" "$2")" ]
}

push_image() { # push_image <app> <tag>: localhost:30500/<app>:<tag>, built locally
  local local_img="$NODE_REGISTRY/$1:$2"
  docker image inspect "$local_img" >/dev/null 2>&1 || die "no local image $local_img (./pipeline ci $1 builds it)"
  forward
  docker tag "$local_img" "$REG/$1:$2"
  docker push -q "$REG/$1:$2" >/dev/null || { docker image rm "$REG/$1:$2" >/dev/null 2>&1; die "push of $1:$2 to the registry failed"; }
  docker image rm "$REG/$1:$2" >/dev/null 2>&1 || true
  ok "image $local_img ($(manifest_digest "$1" "$2"))"
}

push_chart() { # push_chart <app> <version>: helm/<app> as <version>
  forward
  helm package "$ROOT/helm/$1" --version "$2" --app-version "$2" -d "$tmp/chart" >/dev/null
  helm push "$tmp/chart/$1-$2.tgz" "oci://$REG/charts" --plain-http >/dev/null 2>&1 ||
    die "push of chart $1 $2 to the registry failed"
  ok "chart $1 $2 (oci://registry.registry.svc.cluster.local:5000/charts/$1)"
}

publish() { # publish <app> <version>
  check_app "$1"; semver "$2" || die "not a version (semver, e.g. 1.2.0): '$2'"
  ! published "$1" "$2" || die "$1 $2 is already published: versions are never overwritten (pick another --version)"
  step "Publishing $1 $2 to the in-stack registry"
  push_image "$1" "$2"
  push_chart "$1" "$2"
}

case "${1:-}" in
  install)
    step "In-stack registry (namespace registry)"
    kubectl apply -k "$ROOT/system/registry" >/dev/null
    kubectl -n registry rollout status deploy/registry --timeout=180s >/dev/null
    ok "registry ready: images localhost:30500/<app>, charts registry.registry.svc.cluster.local:5000/charts"
    ;;
  published) check_app "${2:?usage: registry.sh published <app> <version>}"; published "$2" "${3:?version}" ;;
  digest)
    forward
    d=$(manifest_digest "${2:?usage: registry.sh digest <app> <tag>}" "${3:?tag}")
    [ -n "$d" ] || die "$2:$3 isn't in the registry"
    echo "$d"
    ;;
  push-image) check_app "${2:?usage: registry.sh push-image <app> <tag>}"; push_image "$2" "${3:?tag}" ;;
  publish) publish "${2:?usage: registry.sh publish <app> <version>}" "${3:?version}" ;;
  seed)
    # Every version an env file pins, for each app. A fresh cluster's
    # registry is empty, so these are built here from the checkout: a quick
    # bootstrap build (no tests, no scan), not a release.
    step "Versions the env files pin (cd/<app>/*.yaml)"
    for dir in "$ROOT"/cd/*/; do
      app=$(basename "$dir")
      versions=$(for f in "$dir"dev.yaml "$dir"staging.yaml "$dir"prod.yaml; do
        [ -f "$f" ] && yq '.version // ""' "$f"
      done | grep -v '^$' | sort -u || true)
      for v in $versions; do
        if published "$app" "$v"; then ok "$app $v: published"; continue; fi
        warn "$app $v: not in this cluster's registry; bootstrap build of $v from this checkout, untested (not a release)"
        docker build -q -t "$NODE_REGISTRY/$app:$v" --build-arg "VERSION=$v" "$ROOT/apps/$app" >/dev/null ||
          die "build of apps/$app failed"
        publish "$app" "$v"
      done
    done
    ;;
  *) die "usage: scripts/registry.sh install | published <app> <version> | digest <app> <tag> | push-image <app> <tag> | publish <app> <version> | seed" ;;
esac
