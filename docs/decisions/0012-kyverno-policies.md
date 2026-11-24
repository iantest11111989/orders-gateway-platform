# 0012: Kyverno admission policies, in Audit first

**Status:** Accepted, 2026-11-24

## Context

The brief (section 9.2) asks for Kyverno admission policies with `kyverno test` cases in CI: block `:latest` and untagged images; require resource requests and limits, probes, non-root and a read-only root filesystem; require the standard `app`, `env` and `team` labels (adding safe defaults); restrict images to approved registries; and require image signatures. Policies start in Audit and move to Enforce once clean. Only the admission controller runs, to save memory.

Image signature verification comes in its own PR, after CI signs images with cosign (supply chain, section 9.3). Until then there's nothing to verify.

## Choices

- **Kyverno 1.20 (chart 3.10.0), admission controller only.** The background, cleanup and reports controllers are off, and so are admission and policy reports, since nothing would aggregate them. Audit results still show up as the admission controller's `kyverno_validating_policy_results_total` metric (scraped through its ServiceMonitor) and as Kubernetes events.
- **CEL policies (`policies.kyverno.io/v1` `ValidatingPolicy` and `MutatingPolicy`).** Kyverno 1.20 no longer runs the older `kyverno.io/v1` `ClusterPolicy` type (it rejects new ones), so these are the only kind it will execute.
- **Two Applications:** `kyverno` (chart, wave 10, with the controllers) and `kyverno-policies` (`policies/`, wave 30, after observability and before the apps at wave 40). `ServerSideApply` for the chart, because Kyverno's CRDs are too large for client-side apply.
- **`failurePolicy: Ignore` on every policy while they audit.** With one Kyverno replica, `Fail` would block every pod creation in the cluster (Argo CD's included) whenever Kyverno restarts. The switch to Enforce revisits this per policy.
- **Scope.** Webhooks skip `kube-system` and `kyverno`. The validation policies cover every other namespace, so Audit shows how the platform's third-party charts measure up too. The label policies apply only in `orders-*`.

| Policy | Checks | Applies to |
| --- | --- | --- |
| `disallow-latest-tag` | every image has a tag or digest, never `:latest` | Pods |
| `require-resources` | `requests.cpu`, `requests.memory`, `limits.memory` on every container | Pods |
| `require-probes` | `livenessProbe` and `readinessProbe` on every container | Deployments, StatefulSets, DaemonSets |
| `require-non-root-readonly` | `runAsNonRoot`, `readOnlyRootFilesystem`, no privilege escalation, `drop: [ALL]` | Pods |
| `restrict-image-registries` | images from `ghcr.io/iantest11111989`, `quay.io`, `registry.k8s.io`, `docker.io`, `ecr-public.aws.com`, `reg.kyverno.io` | Pods |
| `default-labels` (mutate) | adds missing `team: orders`, `env: <namespace suffix>`, `app: <app.kubernetes.io/name>` | Pods in `orders-*` |
| `require-standard-labels` | `app`, `env`, `team` present | Pods in `orders-*` |

- **No CPU limits required**, only a memory limit. CPU limits throttle a container even when the node is idle, while the CPU request already gives it a guaranteed share. A memory limit stops one leak from taking a node down.
- **Probes are checked on the workload, not the Pod,** so Jobs (which run to completion) are exempt and the message points at the object to fix.
- **Labels are added to Pods only,** never to Deployments, so Argo CD's self-heal never sees drift.
- **The registry list** was taken from every image running on a full cluster on 2026-11-24. Bare names like `alpine:3.22.2` fail on purpose: write `docker.io/library/alpine:3.22.2` so the registry is explicit.

## Moving to Enforce

All policies start in Audit (`validationActions: [Audit]`). A policy moves to Enforce, in its own PR, once `kyverno_validating_policy_results_total{result="fail"}` for it stays at zero on a full cluster. The metric has no dry-run label, so server-side dry runs (`kubectl --dry-run=server`, the kind used to test a policy) count too. They also emit PolicyViolation events, so neither tells them apart from real workloads. Run test dry runs in a scratch namespace and leave it out of the query, or check that the flagged resource exists. The app namespaces come first, with exceptions written down for any third-party chart that can't comply. That PR also decides whether the policy keeps `failurePolicy: Ignore` or moves to `Fail` with a second Kyverno replica.

## Tests

- `kyverno test policies/tests` (CLI v1.20.0, the same engine as the cluster) in the new `policies` workflow: 24 cases, at least one pass and one fail per validation policy, and the expected output of the mutation. A deliberately wrong expected result and a wrong mutation output both fail the run.
- The platform workflow's full `./platform up` installs Kyverno and syncs the policies.
