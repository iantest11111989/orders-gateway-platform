#!/bin/sh
# CI: docker-compose.yml's toolbox image tag must be the hash of toolbox/,
# the same tag ./platform computes, so Compose and ./platform run one image.
set -eu
cd "$(dirname "$0")/.."
if command -v sha256sum >/dev/null 2>&1; then sum=sha256sum; else sum="shasum -a 256"; fi
want="sha-$(cd toolbox && find . -type f | LC_ALL=C sort | xargs cat | $sum | cut -c1-12)"
have=$(sed -n 's|^ *image: ghcr.io/iantest11111989/orders-gateway-platform-toolbox:\(sha-[0-9a-f]*\)$|\1|p' docker-compose.yml)
[ "$have" = "$want" ] || { echo "docker-compose.yml uses toolbox:$have, but toolbox/ hashes to $want: update the image line"; exit 1; }
echo "docker-compose.yml toolbox tag is current ($want)"
