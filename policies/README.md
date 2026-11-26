# policies

Kyverno admission policies and their `kyverno test` cases. Argo CD applies everything here except `tests/`, as the `kyverno-policies` Application.

Most policies are in Audit: they report problems but don't block. Two are in Enforce and refuse the pod. Every policy uses `failurePolicy: Ignore`, so if the single Kyverno replica is down, pods still start.

| Policy | Mode | What it checks |
| --- | --- | --- |
| `disallow-latest-tag` | Enforce in `dev`, `staging`, `prod`, `demo` | Every image has a tag or digest, and never `:latest` |
| `disallow-latest-tag-platform` | Audit | The same check everywhere else |
| `verify-image-signatures` | Enforce, `ghcr.io/iantest11111989/orders-gateway*` images only | The image has a keyless cosign signature from this repo's app workflow on `main` |
| `restrict-image-registries` | Audit | Images come from an approved registry, including the in-cluster one at `localhost:30500` |
| `require-resources` | Audit | Every container has CPU and memory requests and a memory limit |
| `require-probes` | Audit | Long-running workloads have liveness and readiness probes |
| `require-non-root-readonly` | Audit | Non-root user, read-only root filesystem, no privilege escalation, no capabilities |
| `standard-labels` | Audit, and mutate | Workloads carry `app`, `env` and `team` labels. In the app namespaces Kyverno adds defaults first. |

`./pipeline` builds unsigned `localhost:30500/` images, which `verify-image-signatures` doesn't match. The `policy` demo shows it refusing an unsigned GHCR image.

A policy moves from Audit to Enforce once it shows no failures on a full cluster (query below).

## Run the tests

```sh
docker run --rm -v "$PWD/policies:/p:ro" -w /p ghcr.io/kyverno/kyverno-cli:v1.20.0 test tests
```

CI runs the same command (`.github/workflows/policies.yml`). The `verify-image-signatures` cases need network access, because they fetch real signatures from GHCR and Sigstore.

## See what Audit finds

Audit failures are counted in Prometheus:

```promql
sum by (policy_name, resource_namespace) (
  kyverno_validating_policy_results_total{result="fail", resource_namespace!="default"}
  or kyverno_image_validating_policy_results_total{result="fail", resource_namespace!="default"}
)
```

Each failure is also a `PolicyViolation` event: `kubectl get events -A --field-selector reason=PolicyViolation`. Background scans are off, so Kyverno only checks a pod when it is created or updated.

`./platform verify` does a test dry run in `dev`, so expect one `disallow-latest-tag` failure there per run.

## Add a policy

1. Add it here in Audit (`validationActions: [Audit]`, `failurePolicy: Ignore`).
2. Add a compliant and a non-compliant resource to `tests/resources.yaml`, and the expected results to `tests/kyverno-test.yaml`.
3. Run the tests, then add a row to the table above.
