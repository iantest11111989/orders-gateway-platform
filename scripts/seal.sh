#!/usr/bin/env bash
# Prints a SealedSecret for <namespace>/<name> with the given key=value
# pairs, sealed offline with the committed demo certificate
# (stack/security/sealed-secrets/manifests/demo-cert.pem), so no cluster is needed.
# Runs in the toolbox (kubeseal, kubectl):
#   ./platform shell scripts/seal.sh monitoring grafana-admin admin-user=admin admin-password=...
# Output goes to stdout; commit it under stack/<group>/<component>/.
# DEMO ONLY: the matching private key is committed too, so these values are
# readable by anyone with the repo.
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <namespace> <name> key=value..." >&2; exit 2; }
ns=$1 name=$2
shift 2
cert="$(cd "$(dirname "$0")/.." && pwd)/system/sealed-secrets/manifests/demo-cert.pem"

args=()
for kv in "$@"; do
  [[ $kv == *=* ]] || { echo "not key=value: $kv" >&2; exit 2; }
  args+=(--from-literal="$kv")
done

kubectl create secret generic "$name" -n "$ns" "${args[@]}" --dry-run=client -o yaml |
  kubeseal --cert "$cert" --format yaml
