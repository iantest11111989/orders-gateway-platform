# policies

Kyverno admission policies (`ValidatingPolicy` and `MutatingPolicy`, Kyverno 1.20) and their `kyverno test` cases. Argo CD applies everything here except `tests/` (the `kyverno-policies` Application, wave 30). Most policies are in **Audit**: they report, they don't block. Two are in **Enforce** and reject the pod: `disallow-latest-tag` in the app namespaces (`dev`, `staging`, `prod`, `demo`), and `verify-image-signatures` wherever the app image runs. Every policy uses `failurePolicy: Ignore`: with one Kyverno replica, a Kyverno outage must not stop pods from starting.

| Policy | Mode | What it checks |
| --- | --- | --- |
| `disallow-latest-tag` | Enforce (app namespaces) | Every image has an explicit tag or digest, never `:latest`, so what runs is what was reviewed |
| `disallow-latest-tag-platform` | Audit | The same check for every other namespace (third-party charts are reported, not blocked) |
| `verify-image-signatures` | Enforce (app image only) | The app image carries a keyless cosign signature from this repo's CD workflow on main |
| `restrict-image-registries` | Audit | Images come only from this repo's GHCR namespace and the upstream registries the pinned charts use |
| `require-resources` | Audit | Every container has CPU and memory requests and a memory limit (no CPU limit: it only throttles) |
| `require-probes` | Audit | Long-running workloads have liveness and readiness probes |
| `require-non-root-readonly` | Audit | Non-root user, read-only root filesystem, no privilege escalation, no capabilities |
| `standard-labels` | Audit (+ mutate) | Workloads carry `app`, `env` and `team` labels; in the app namespaces Kyverno adds safe defaults first |

A policy moves from Audit to Enforce once the query below shows no failures for it on a full cluster.

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
3. Run the tests, then add a row to the table at the top.
