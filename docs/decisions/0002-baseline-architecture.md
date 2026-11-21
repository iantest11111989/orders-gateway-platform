# 0002: Baseline architecture

**Status:** Accepted, 2026-11-21

## Context

The repo must run on a clean machine with only Docker, fit in 6 CPUs and 12 GB RAM, and show production practice for running, shipping, observing and securing a small service. It should use open-source tools and be reproducible by any reviewer.

## Options

The main alternatives considered for each area are listed in the table. The README's "Why these choices" section (coming) explains each in more depth.

| Area | Choice | Alternatives considered |
| --- | --- | --- |
| Local cluster | kind, 1 control plane + 2 workers | k3d, minikube |
| Packaging | Helm chart | Kustomize |
| GitOps | Argo CD, app-of-apps, self-managed after bootstrap | Flux |
| Progressive delivery | Argo Rollouts with `workloadRef` (the app stays a Deployment in Git) | Flagger, Rollout as the primary object |
| Traffic | Gateway API with Envoy Gateway | ingress-nginx (retired) |
| TLS | cert-manager with a local demo CA | mkcert, self-signed per service |
| Metrics | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | Datadog, VictoriaMetrics |
| Logs | Loki single binary + Alloy | Elasticsearch/OpenSearch, Promtail (deprecated) |
| Tracing | None for now | OpenTelemetry + Tempo |
| Policy | Kyverno (admission controller only) | OPA Gatekeeper |
| Secrets | Sealed Secrets with a committed demo key | External Secrets + a local Vault |
| Image scanning | Trivy in CI + Trivy Operator in cluster | Grype |
| Signing | cosign keyless via GitHub OIDC, verified by Kyverno | cosign with a stored key |
| CI | GitHub Actions | |
| Dependency updates | Renovate | Dependabot |
| Environments | dev, staging, prod as namespaces in one cluster | one cluster per environment |
| App language | Go (standard library + Prometheus client) | |

## Choice

As in the table. These choices are fixed for this project; changing one needs the owner's approval and a new decision record.

## Consequences

- One cluster hosts every environment, so the budget is shared and the environments are not isolated the way separate clusters would be. The README's "Production differences" section will cover this.
- Using `workloadRef` keeps the Git source of truth a plain Deployment, at the cost of a slightly unusual setup (the Rollout scales the Deployment to zero and runs the pods itself) that must be documented clearly.
- The committed Sealed Secrets key is **demo only** and is flagged as such everywhere it appears.
- Without tracing, request-level debugging relies on logs carrying `request_id`.
