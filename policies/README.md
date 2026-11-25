# policies

Kyverno admission policies (`ValidatingPolicy` and `MutatingPolicy`, Kyverno 1.20) and their `kyverno test` cases. Argo CD applies everything here except `tests/` (the `kyverno-policies` Application, wave 30). Every policy is in **Audit**: it reports, it doesn't block. See [decision 0012](../docs/decisions/0012-kyverno-policies.md) for what each one checks and how they move to Enforce.

## Run the tests

```sh
docker run --rm -v "$PWD/policies:/p:ro" -w /p ghcr.io/kyverno/kyverno-cli:v1.20.0 test tests
```

CI runs the same command (`.github/workflows/policies.yml`). The
`verify-image-signatures` cases need network access: they fetch real
signatures from GHCR and Sigstore's trust root.

## See what Audit finds on a live cluster

Failed checks don't block anything yet; they're counted in Prometheus:

```promql
sum by (policy_name, resource_namespace) (
  kyverno_validating_policy_results_total{result="fail"}
  or kyverno_image_validating_policy_results_total{result="fail"}
)
```

Each failure is also a `PolicyViolation` event on the resource
(`kubectl get events -A --field-selector reason=PolicyViolation`). Only
admission requests are checked (background scans are off), so a pod that
already exists shows up only once it's created or updated again.
(Metric name and labels checked on ogp with Kyverno 1.20.)

## Adding a policy

1. Add the policy here, in Audit (`validationActions: [Audit]`, `failurePolicy: Ignore`).
2. Add a compliant and a non-compliant resource to `tests/resources.yaml`, and their expected results to `tests/kyverno-test.yaml`.
3. Run the tests, then add a row to the table in decision 0012.
