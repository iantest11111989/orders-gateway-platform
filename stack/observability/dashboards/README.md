# dashboards

Grafana dashboards as JSON. Grafana loads them automatically, and every panel has a short description.

| Dashboard | What it shows |
| --- | --- |
| [`platform-overview`](platform-overview.json) | Start here. Firing alerts, Argo CD apps not Synced or Healthy, pods not Ready, targets down, each environment's version and traffic, the resource budget, and links to the rest. |
| [`orders-gateway`](orders-gateway.json) | Per environment: SLO error budget and burn rates, traffic and errors, latency, pods by version, CPU and memory per pod, warning and error logs. |
| [`argocd`](argocd.json) | Applications out of sync or unhealthy, failed syncs, syncs per app, reconcile time. |
| [`kyverno`](kyverno.json) | Refused requests, Audit findings and policy errors by policy and namespace. Shows which policy is ready for Enforce. |
| [`security`](security.json) | Security alerts, image vulnerability findings, failed signature checks, and whether Kyverno, Sealed Secrets and Trivy Operator are up. |
| [`budget`](budget.json) | CPU and memory against 6 CPU / 12 GiB over time, by namespace and per node, plus OOM kills. The same numbers as `./platform budget`. |

Open one at `http://localhost:3000/d/<name>`, for example <http://localhost:3000/d/orders-gateway>. Grafana also ships the standard Kubernetes dashboards from kube-prometheus-stack.

## Change a dashboard

Git is the source. Changes made only in the Grafana UI are lost when Grafana restarts.

1. Edit the dashboard in Grafana, then use **Export → Export as JSON** with "Export for sharing externally" off. Save it over `stack/observability/dashboards/<name>.json`. Or edit the JSON directly.
2. Run `scripts/dashboards.sh gen`. It writes the ConfigMap that Argo CD applies, `stack/kube-prometheus-stack/manifests/dashboard-<name>.yaml`.
3. Run `scripts/dashboards.sh check`. CI runs it too. It checks that the ConfigMap is up to date, every panel has a description and every PromQL query parses.
