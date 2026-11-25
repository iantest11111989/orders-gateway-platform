# dashboards

Grafana dashboards as JSON, provisioned automatically. Every panel has a plain-English description ([decision 0023](../docs/decisions/0023-dashboards-as-code.md)).

| Dashboard | What it shows |
| --- | --- |
| [`orders-gateway`](orders-gateway.json) | Per environment: SLO error budget (last 24 h) and burn rates, firing SLO alerts, traffic and errors, latency percentiles and share under 300 ms, pods by version (canary), CPU and memory per pod, warn and error logs |
| [`argocd`](argocd.json) | Applications out of sync or unhealthy, failed syncs, every Application's status, syncs per app, reconcile time, Git requests |
| [`argo-rollouts`](argo-rollouts.json) | Each Rollout's phase and replicas, recent canary AnalysisRuns and their checks, Rollout events, controller errors |
| [`kyverno`](kyverno.json) | Requests refused (Deny), Audit findings, policy errors, admission latency, results by policy, failures by policy and namespace (which policy is ready for Enforce) |

Open them at `https://grafana.localtest.me/d/<name>` (e.g. <https://grafana.localtest.me/d/orders-gateway>) (`./platform urls` prints the login). Grafana also ships the standard Kubernetes dashboards from kube-prometheus-stack.

## Changing a dashboard

1. Edit it in Grafana, then **Export → Export as JSON** (leave "Export for sharing externally" off), and save it over `dashboards/<name>.json`. Or edit the JSON directly.
2. Run `scripts/dashboards.sh gen`. It writes the ConfigMap Argo CD applies (`gitops/manifests/monitoring/dashboard-<name>.yaml`, label `grafana_dashboard: "1"`).
3. Run `scripts/dashboards.sh check` (CI runs it too). It checks that the ConfigMap is up to date, that every panel has a description, and that every PromQL query parses (with `promtool`).

Changes made only in the Grafana UI are lost when Grafana restarts. Git is the source.
