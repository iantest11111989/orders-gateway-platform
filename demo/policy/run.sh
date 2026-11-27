#!/usr/bin/env bash
# ./platform demo policy [dev|staging|prod]: Kyverno refuses, in the
# environment's namespace, an orders-gateway image that main's app workflow
# didn't sign (the old staging/prod image) and a :latest image; a signed
# image is admitted (dry run). Nothing it tries ever runs.
# Runs in the toolbox; shared helpers in demo/lib.sh.
# shellcheck source=demo/lib.sh
source "$(dirname "$0")/../lib.sh"

# --- policy helpers ----------------------------------------------------------

# Built before image signing; staging and prod ran it until
# 2026-11-25. Still in GHCR, never signed.
UNSIGNED_IMAGE=ghcr.io/iantest11111989/orders-gateway@sha256:09c2177caeb2c7b701c1f091fd65600065c836d4b25b930bff82cb6ec62b3476
SIGNED_IMAGE=ghcr.io/iantest11111989/orders-gateway:v1

# A pod that meets Pod Security "restricted" (which the app namespaces enforce, and
# which the API server checks before Kyverno), so the image is the only
# thing a policy can object to.
policy_pod() { # policy_pod <name> <image>
  jq -n --arg name "$1" --arg ns "$NS" --arg image "$2" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: $name, namespace: $ns, labels: {"app.kubernetes.io/name": "policy-demo"}},
    spec: {restartPolicy: "Never",
      securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "app", image: $image,
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        resources: {requests: {cpu: "10m", memory: "16Mi"}, limits: {memory: "32Mi"}}}]}}'
}

# Creates the pod for real (no dry run) and expects Kyverno to refuse it.
expect_denied() { # expect_denied <name> <image> <policy>
  local out
  show "kubectl create -f -   # Pod $1, image $2"
  if out=$(policy_pod "$1" "$2" | kubectl create -f - 2>&1); then
    kubectl -n "$NS" delete pod "$1" --wait=false >/dev/null 2>&1 || true
    die "Kyverno let $2 in (is $3 in Deny? see stack/kyverno/policies/)"
  fi
  grep -q "$3" <<<"$out" || die "$2 was refused, but not by $3: $out"
  ok "refused by $3: $2"
  note "the API server's answer:"
  sed -E 's/^Error from server[^:]*: //; s/^error when creating "[^"]*": //; s/admission webhook "[^"]*" denied the request: //' <<<"$out" | fold -s -w 76 | sed 's/^/      /' >&2
}

demo_policy() {
  step "Demo: Kyverno refusing an unsigned image and a :latest image"
  echo "  In the app namespaces two policies deny: orders-gateway"
  echo "  images must carry a cosign signature from main's app workflow, and no image"
  echo "  may be :latest or untagged. Each pod below is created for real in $NS"
  echo "  (no dry run) and meets Pod Security \"restricted\", so the image is the only"
  echo "  thing wrong with it. Takes under a minute."
  echo "  Watch: ./platform shell -c 'kubectl get events -n $NS --field-selector reason=PolicyViolation -w'"
  run kubectl get namespace "$NS" -L pod-security.kubernetes.io/enforce
  note "the app namespaces enforce Pod Security restricted; the pods below meet it, so only the image is wrong"

  run kubectl get clusterpolicies,imagevalidatingpolicies || true
  note "the pod each step creates (only the name and image change):"
  policy_pod policy-example IMAGE | yq -P | indent
  step "1. An orders-gateway image nobody signed"
  echo "  The image staging and prod ran until today, built before signing existed." >&2
  expect_denied policy-unsigned "$UNSIGNED_IMAGE" verify-image-signatures

  step "2. A :latest image"
  expect_denied policy-latest docker.io/library/busybox:latest disallow-latest-tag

  step "3. For contrast: the signed v1 image (server-side dry run, nothing starts)"
  local out
  show "kubectl create --dry-run=server -o name -f -   # Pod policy-signed, image $SIGNED_IMAGE"
  if out=$(policy_pod policy-signed "$SIGNED_IMAGE" | kubectl create --dry-run=server -o name -f - 2>&1); then
    printf '%s\n' "$out" | indent
    ok "admitted: $SIGNED_IMAGE carries main's signature"
  else
    die "the signed image was refused: $out"
  fi
  [ "$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=policy-demo -o name | grep -c .)" -eq 0 ] ||
    die "a policy-demo pod exists in $NS"
  ok "nothing from this demo is running in $NS"
  check "Grafana, Kyverno dashboard (give it a minute: Prometheus scrapes every 30 s)" "$(dash_url kyverno)" \
    "Pods refused (24 h): up by the 2 refusals above" \
    "Results by policy: a fail for verify-image-signatures and one for disallow-latest-tag" \
    "Admission requests: allowed vs refused: a red blip for the refusals"
  check "the refusals as Kubernetes events" "" \
    "./platform kubectl get events -A --field-selector reason=PolicyViolation --sort-by=.lastTimestamp | tail"
}

demo_policy
finish
