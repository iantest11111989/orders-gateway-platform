#!/usr/bin/env bash
# ./platform urls: every URL and login. Services are added as their PRs land.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cluster_exists || die "no cluster yet; run ./platform up first"

step "URLs (all *.localtest.me names resolve to 127.0.0.1)"
echo "  The gateway, HTTPS and the web UIs arrive in later pull requests."
echo "  Until then, use ./platform shell and kubectl."
