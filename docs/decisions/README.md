# Decision log

One file per notable decision, numbered in order: `NNNN-short-title.md`.

Each record has four parts:

- **Context:** what problem we faced and what constrained us.
- **Options:** what we considered.
- **Choice:** what we picked.
- **Consequences:** what follows from it, good and bad.

Records are not edited after they are accepted. If a decision changes, add a new record that supersedes the old one and link the two.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-record-decisions.md) | Record decisions in this log | Accepted |
| [0002](0002-baseline-architecture.md) | Baseline architecture | Accepted |
| [0003](0003-gitops-directory-name.md) | Argo CD Applications live in `gitops/` | Accepted |
| [0004](0004-toolbox-and-cluster.md) | Toolbox container, `./platform` CLI and the kind cluster | Accepted |
| [0005](0005-gitops-layout.md) | GitOps layout: app-of-apps as a Helm chart, sync waves | Accepted |
| [0006](0006-slo-rules.md) | How the orders-gateway SLO is measured and alerted | Accepted |
| [0007](0007-observability-stack.md) | Observability stack layout, sizing and security | Accepted |
| [0008](0008-gateway-and-tls.md) | HTTPS entry point: Envoy Gateway, cert-manager and a demo CA | Accepted |
| [0009](0009-chart-and-environments.md) | orders-gateway Helm chart and the dev/staging/prod environments | Accepted |
| [0010](0010-renovate.md) | Renovate keeps every pin current | Accepted |
| [0011](0011-canary-rollouts.md) | Prod canary with Argo Rollouts, Gateway API weights and SLO analysis | Accepted |
| [0012](0012-kyverno-policies.md) | Kyverno admission policies, in Audit first | Accepted |
| [0013](0013-image-signing.md) | Keyless cosign signatures and BuildKit SBOMs for the app image | Accepted |
| [0014](0014-promotion.md) | CI promotes every signed image to dev; staging and prod move by PR | Accepted |
| [0015](0015-promotion-prs.md) | CI opens the staging and prod promotion PRs | Accepted |
| [0016](0016-trivy-image-scan.md) | Trivy scans the app image in CI | Accepted |
| [0017](0017-network-policies.md) | NetworkPolicies for the platform namespaces | Accepted |
| [0018](0018-sealed-secrets.md) | Sealed Secrets with a committed demo key; no plain Secrets in Git | Accepted |
| [0019](0019-rescan-running-images.md) | Daily rescan of the images the environments run | Accepted |
| [0020](0020-demos-in-a-copy-of-prod.md) | The canary demos run in a copy of prod | Accepted |
| [0021](0021-trivy-operator.md) | Trivy Operator in the cluster, trimmed to fit the budget | Accepted |
| [0022](0022-enforce-in-orders.md) | Enforce the tag and signature policies in the orders namespaces | Accepted |
| [0023](0023-dashboards-as-code.md) | Grafana dashboards as code, checked in CI | Accepted |
| [0024](0024-patch-promoter.md) | An in-cluster patch promoter, a pause file and an order trickle | Accepted |
| [0025](0025-security-alerts-and-routing.md) | Security component alerts, and routing every alert to a local receiver | Accepted |
| [0026](0026-compose-entrypoint.md) | docker compose is the entry point; one `ready` service bootstraps the cluster | Accepted |
