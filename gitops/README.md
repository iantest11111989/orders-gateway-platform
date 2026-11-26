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
| `argocd` | 0 | Argo CD, managing itself |
| `traefik` | 10 | Ingress controller: 2 replicas + PDB, plain HTTP, one entrypoint per host port (`values/traefik.yaml`) |
| `metrics-server` | 10 | CPU/memory metrics for HPAs and `kubectl top` |
| `kube-prometheus-stack` | 20 | Prometheus, Alertmanager, Grafana, exporters |
| `loki` | 20 | Loki, single binary |
| `alloy` | 20 | Log collection DaemonSet |
| `platform-alerts` | 25 | PrometheusRules from `alerts/` |
| `edge` | 25 | Ingresses for Argo CD (:8081), Grafana (:3000), Prometheus (:9090) and Alertmanager (:9093) (`manifests/edge/`) |
| `orders-gateway-dev`, `-staging`, `-prod` | 40 | orders-gateway per environment: `charts/orders-gateway` + `environments/<env>/values.yaml` |
