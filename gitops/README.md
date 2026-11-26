# gitops

Everything Argo CD syncs, as an app of apps: one root Application renders one child Application per component, ordered by sync wave.

- `root.yaml`: the root Application. `./platform up` applies it once, with `REPO_URL`/`REVISION`.
- `apps/`: a Helm chart. Each template is one Argo CD Application, and every template uses `{{ .Values.repo.url }}` and `{{ .Values.repo.revision }}` for this repo.
- `values/<component>.yaml`: Helm values per component.
- `manifests/<component>/`: plain manifests for Applications that aren't a Helm chart.

Sync waves: -10 CRDs, 0 Argo CD, 10 controllers, 20 observability, 30 policies, 40 apps. Waves wait for each child to be Healthy (Application health check in `values/argocd.yaml`).

| Application | Wave | What |
| --- | --- | --- |
| `prometheus-operator-crds` | -10 | Prometheus Operator CRDs |
| `gateway-crds` | -10 | Gateway API and Envoy Gateway CRDs |
| `argocd` | 0 | Argo CD, managing itself |
| `cert-manager` | 10 | Certificates from the demo CA |
| `envoy-gateway` | 10 | Gateway API controller (Envoy) |
| `argo-rollouts` | 10 | Argo Rollouts controller + Gateway API plugin, read-only dashboard |
| `metrics-server` | 10 | CPU/memory metrics for HPAs and `kubectl top` |
| `platform-gateway` | 15 | Demo CA, `*.localtest.me` certificate, Gateway, HTTP→HTTPS redirect, UI routes (`manifests/gateway/`) |
| `kube-prometheus-stack` | 20 | Prometheus, Alertmanager, Grafana, exporters |
| `loki` | 20 | Loki, single binary |
| `alloy` | 20 | Log collection DaemonSet |
| `platform-alerts` | 25 | PrometheusRules from `alerts/` |
| `dev`, `staging`, `prod` | 40 | orders-gateway per environment: `charts/orders-gateway` + `environments/<env>/values.yaml` |
