#!/bin/sh
# Validates and unit-tests every PrometheusRule in alerts/ with promtool, and
# checks every alert has a runbook_url whose file exists in runbooks/.
# Needs only Docker; CI runs it on every pull request that touches alerts/.
#
#   scripts/test-alerts.sh
set -eu
cd "$(dirname "$0")/.."

# Pinned by multi-arch index digest. Renovate keeps these current.
YQ_IMAGE=mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2
PROM_IMAGE=prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06

# PrometheusRule objects wrap plain Prometheus rule groups in .spec; promtool
# reads the plain form, so extract it into .build/ (git-ignored).
rm -rf .build/alerts
mkdir -p .build/alerts
for f in alerts/*.yaml; do
  name=$(basename "$f" .yaml)
  docker run --rm -i "$YQ_IMAGE" '.spec' <"$f" >".build/alerts/$name.rules.yaml"
done

docker run --rm -v "$PWD":/w -w /w --entrypoint promtool "$PROM_IMAGE" \
  check rules .build/alerts/*.rules.yaml
# shellcheck disable=SC2046 # one argument per test file
docker run --rm -v "$PWD":/w -w /w --entrypoint promtool "$PROM_IMAGE" \
  test rules $(ls alerts/tests/*.test.yaml)

# Every alert needs a runbook, and every runbook link must resolve.
status=0
# One yq call per file: concatenated files would read as one YAML document,
# where the last file's "groups" hides the others.
for url in $(for f in .build/alerts/*.rules.yaml; do docker run --rm -i "$YQ_IMAGE" \
    '.groups[].rules[] | select(has("alert")) | .alert + "=" + (.annotations.runbook_url // "")' <"$f"; done); do
  alert=${url%%=*}
  link=${url#*=}
  want="https://github.com/iantest11111989/orders-gateway-platform/blob/main/runbooks/$alert.md"
  if [ "$link" != "$want" ]; then
    echo "FAIL $alert: runbook_url must be $want (got '${link}')"; status=1
  elif [ ! -f "runbooks/$alert.md" ]; then
    echo "FAIL $alert: runbooks/$alert.md does not exist"; status=1
  else
    echo "ok   $alert -> runbooks/$alert.md"
  fi
done
exit "$status"
