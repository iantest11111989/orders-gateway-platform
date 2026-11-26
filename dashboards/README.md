# dashboards

Grafana dashboards as JSON, provisioned automatically. Every panel has a plain-English description.

| Dashboard | What it shows |
| --- | --- |
| [`orders-gateway`](orders-gateway.json) | Per environment: SLO error budget (last 24 h) and burn rates, firing SLO alerts, traffic and errors, latency percentiles and share under 250 ms, pods by version, CPU and memory per pod, warn and error logs |
| [`argocd`](argocd.json) | Applications out of sync or unhealthy, failed syncs, every Application's status, syncs per app, reconcile time, Git requests |
| [`kyverno`](kyverno.json) | Requests refused (Deny), Audit findings, policy errors, admission latency, results by policy, failures by policy and namespace (which policy is ready for Enforce) |
| [`budget`](budget.json) | The whole stack's CPU and memory against 6 CPU / 12 GiB (the same numbers as `./platform budget`, over time), by namespace and per node against its cap, and OOM kills |
| [`platform-overview`](platform-overview.json) | The first one to open: pages and tickets firing, Argo CD apps not Synced or Healthy, pods not Ready, targets down, every firing alert, each environment's version, burn rate and order rate, the resource budget, and links to the rest |
| [`security`](security.json) | Security alerts firing, critical and high findings in our app's images, refusals and failed signature checks, Kyverno, Sealed Secrets and Trivy Operator up, findings by namespace and image, config audit findings, admission results |

Open them at `http://localhost:3000/d/<name>` (e.g. <http://localhost:3000/d/orders-gateway>) (`./platform urls` prints the login). Grafana also ships the standard Kubernetes dashboards from kube-prometheus-stack.

## Changing a dashboard

1. Edit it in Grafana, then **Export → Export as JSON** (leave "Export for sharing externally" off), and save it over `dashboards/<name>.json`. Or edit the JSON directly.
2. Run `scripts/dashboards.sh gen`. It writes the ConfigMap Argo CD applies (`gitops/manifests/monitoring/dashboard-<name>.yaml`, label `grafana_dashboard: "1"`).
3. Run `scripts/dashboards.sh check` (CI runs it too). It checks that the ConfigMap is up to date, that every panel has a description, and that every PromQL query parses (with `promtool`).

Changes made only in the Grafana UI are lost when Grafana restarts. Git is the source.
