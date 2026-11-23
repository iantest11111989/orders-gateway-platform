# gitops

Everything Argo CD syncs. See [decision 0005](../docs/decisions/0005-gitops-layout.md).

- `root.yaml`: the root Application. `./platform up` applies it once, with `REPO_URL`/`REVISION`.
- `apps/`: a Helm chart. Each template is one Argo CD Application, and every template uses `{{ .Values.repo.url }}` and `{{ .Values.repo.revision }}` for this repo.
- `values/<component>.yaml`: Helm values per component.
- `manifests/<component>/`: plain manifests for Applications that aren't a Helm chart.

Sync waves: -10 CRDs, 0 Argo CD, 10 controllers, 20 observability, 30 policies, 40 apps. Waves wait for each child to be Healthy (Application health check in `values/argocd.yaml`).

| Application | Wave | What |
| --- | --- | --- |
| `prometheus-operator-crds` | -10 | Prometheus Operator CRDs |
| `gateway-crds` | -10 | Gateway API and Envoy Gateway CRDs ([0008](../docs/decisions/0008-gateway-and-tls.md)) |
| `argocd` | 0 | Argo CD, managing itself |
| `cert-manager` | 10 | Certificates from the demo CA |
| `envoy-gateway` | 10 | Gateway API controller (Envoy) |
| `platform-gateway` | 15 | Demo CA, `*.localtest.me` certificate, Gateway, HTTP→HTTPS redirect, UI routes (`manifests/gateway/`) |
| `kube-prometheus-stack` | 20 | Prometheus, Alertmanager, Grafana, exporters ([0007](../docs/decisions/0007-observability-stack.md)) |
| `loki` | 20 | Loki, single binary |
| `alloy` | 20 | Log collection DaemonSet |
| `platform-alerts` | 25 | PrometheusRules from `alerts/` |
