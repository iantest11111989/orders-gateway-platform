# policies

Kyverno admission policies (`ValidatingPolicy` and `MutatingPolicy`, Kyverno 1.20) and their `kyverno test` cases. Argo CD applies everything here except `tests/` (the `kyverno-policies` Application, wave 30). Most policies are in **Audit**: they report, they don't block. `disallow-latest-tag` (in the app namespaces `dev`, `staging`, `prod`, `demo`) and `verify-image-signatures` are in **Enforce** and reject the pod ([decision 0022](../docs/decisions/0022-enforce-in-orders.md)). `disallow-latest-tag-platform` keeps the tag check in Audit for the rest of the cluster. See [decision 0012](../docs/decisions/0012-kyverno-policies.md) for what each one checks and how they move to Enforce.

## Run the tests

```sh
docker run --rm -v "$PWD/policies:/p:ro" -w /p ghcr.io/kyverno/kyverno-cli:v1.20.0 test tests
```

CI runs the same command (`.github/workflows/policies.yml`). The
`verify-image-signatures` cases need network access: they fetch real
signatures from GHCR and Sigstore's trust root.

## See what Audit finds on a live cluster

Failed checks of the Audit policies don't block anything; they're counted in Prometheus (so are the Deny policies' rejections):

```promql
sum by (policy_name, resource_namespace) (
  kyverno_validating_policy_results_total{result="fail", resource_namespace!="default"}
  or kyverno_image_validating_policy_results_total{result="fail", resource_namespace!="default"}
)
```

Each failure is also a `PolicyViolation` event on the resource
(`kubectl get events -A --field-selector reason=PolicyViolation`). Only
admission requests are checked (background scans are off), so a pod that
already exists shows up only once it's created or updated again.
(Metric name and labels checked on ogp with Kyverno 1.20.) The query leaves out
`default`, where earlier versions of `./platform verify` made a test dry run. `verify` now makes its
dry run in `dev`, so expect one `disallow-latest-tag` failure there per run.

## Adding a policy

1. Add the policy here, in Audit (`validationActions: [Audit]`, `failurePolicy: Ignore`).
2. Add a compliant and a non-compliant resource to `tests/resources.yaml`, and their expected results to `tests/kyverno-test.yaml`.
3. Run the tests, then add a row to the table in decision 0012.
