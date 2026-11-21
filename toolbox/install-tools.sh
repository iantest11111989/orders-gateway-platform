#!/bin/sh
# Downloads every pinned tool for one architecture and checks each file
# against the SHA-256 checksum the project publishes with that release.
# Usage: install-tools.sh <amd64|arm64> <dest-dir>
set -eu
ARCH="$1"
DEST="$2"
# shellcheck disable=SC1091 # copied in by the Dockerfile
. /tmp/versions.env
mkdir -p "$DEST"
WORK=$(mktemp -d)
cd "$WORK"

gh() { echo "https://github.com/$1/releases/download/$2/$3"; }

# verify <file> <checksum-file>: accepts "<hash>  <name>" (GNU),
# "SHA256 (<name>) = <hash>" (BSD) or a bare hash.
verify() {
  name=$(basename "$1")
  want=$(awk -v n="$name" '
    $2 == n || $2 == "*"n { print $1; exit }
    $1 == "SHA256" && $2 == "("n")" { print $4; exit }
    NF == 1 { print $1; exit }' "$2")
  [ -n "$want" ] || { echo "no checksum for $name" >&2; exit 1; }
  echo "$want  $1" | sha256sum -c - >/dev/null || { echo "CHECKSUM MISMATCH: $name" >&2; exit 1; }
  echo "verified $name"
}

# tool <install-name> <download-url> <checksum-url> [path-inside-tar.gz]
tool() {
  file=$(basename "$2")
  curl -fsSL --retry 3 -o "$file" "$2"
  curl -fsSL --retry 3 -o "$file.sums" "$3"
  verify "$file" "$file.sums"
  if [ $# -ge 4 ]; then
    tar -xzf "$file" "$4"
    install -m 0755 "$4" "$DEST/$1"
  else
    install -m 0755 "$file" "$DEST/$1"
  fi
}

A=$ARCH
f="kind-linux-$A"
tool kind "$(gh kubernetes-sigs/kind "$KIND_VERSION" "$f")" "$(gh kubernetes-sigs/kind "$KIND_VERSION" "$f.sha256sum")"

u="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$A/kubectl"
tool kubectl "$u" "$u.sha256"

u="https://get.helm.sh/helm-$HELM_VERSION-linux-$A.tar.gz"
tool helm "$u" "$u.sha256sum" "linux-$A/helm"

v=${KUBESEAL_VERSION#v}
tool kubeseal "$(gh bitnami-labs/sealed-secrets "$KUBESEAL_VERSION" "kubeseal-$v-linux-$A.tar.gz")" \
  "$(gh bitnami-labs/sealed-secrets "$KUBESEAL_VERSION" "sealed-secrets_${v}_checksums.txt")" kubeseal

tool cosign "$(gh sigstore/cosign "$COSIGN_VERSION" "cosign-linux-$A")" \
  "$(gh sigstore/cosign "$COSIGN_VERSION" cosign_checksums.txt)"

tool k6 "$(gh grafana/k6 "$K6_VERSION" "k6-$K6_VERSION-linux-$A.tar.gz")" \
  "$(gh grafana/k6 "$K6_VERSION" "k6-$K6_VERSION-checksums.txt")" "k6-$K6_VERSION-linux-$A/k6"

tool argocd "$(gh argoproj/argo-cd "$ARGOCD_VERSION" "argocd-linux-$A")" \
  "$(gh argoproj/argo-cd "$ARGOCD_VERSION" cli_checksums.txt)"

tool kubectl-argo-rollouts "$(gh argoproj/argo-rollouts "$ROLLOUTS_VERSION" "kubectl-argo-rollouts-linux-$A")" \
  "$(gh argoproj/argo-rollouts "$ROLLOUTS_VERSION" argo-rollouts-checksums.txt)"

tool jq "$(gh jqlang/jq "$JQ_VERSION" "jq-linux-$A")" "$(gh jqlang/jq "$JQ_VERSION" sha256sum.txt)"

tool yq "$(gh mikefarah/yq "$YQ_VERSION" "yq_linux_$A")" "$(gh mikefarah/yq "$YQ_VERSION" checksums-bsd)"

# promtool (from the Prometheus release) for alert-rule checks and tests
v=${PROMETHEUS_VERSION#v}
tool promtool "$(gh prometheus/prometheus "$PROMETHEUS_VERSION" "prometheus-$v.linux-$A.tar.gz")" \
  "$(gh prometheus/prometheus "$PROMETHEUS_VERSION" sha256sums.txt)" "prometheus-$v.linux-$A/promtool"

cd / && rm -rf "$WORK"
