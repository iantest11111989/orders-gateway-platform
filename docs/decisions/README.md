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
