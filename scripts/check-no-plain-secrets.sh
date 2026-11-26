#!/usr/bin/env bash
# Fails if the repo holds a plain Kubernetes Secret or a private key, so
# secrets only ever land in Git sealed (SealedSecret).
# The one exception is the DEMO ONLY Sealed Secrets key, committed on
# purpose and allowlisted here by path.
# CI runs it in the platform workflow's lint job; it needs only git and grep.
set -euo pipefail
cd "$(dirname "$0")/.."

# DEMO ONLY: the committed Sealed Secrets key. Nothing else.
allow='^system/sealed-secrets/manifests/demo-key\.yaml$'

found=0
while IFS= read -r f; do
  [[ $f =~ $allow ]] && continue
  if grep -Eq '^kind:[[:space:]]*["'\'']?Secret["'\'']?[[:space:]]*$' "$f"; then
    echo "::error file=$f::plain Kubernetes Secret; seal it (scripts/seal.sh) instead"
    found=1
  fi
done < <(git ls-files '*.yaml' '*.yml' '*.json')

while IFS= read -r f; do
  [[ $f =~ $allow ]] && continue
  echo "::error file=$f::private key in the repo"
  found=1
done < <(git grep -lE -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' || true)

[ "$found" -eq 0 ] && echo "no plain Secrets or private keys (allowlisted: the demo Sealed Secrets key)"
exit "$found"
