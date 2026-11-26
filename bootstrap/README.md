# bootstrap

Everything Argo CD syncs, as an app of apps: one root Application renders one child Application per component, ordered by sync wave.

- `root.yaml`: the root Application. `./platform up` applies it, pointed at the in-stack Git server.
- `apps/`: a Helm chart. Each template is one Argo CD Application, and every template uses `{{ .Values.repo.url }}` and `{{ .Values.repo.revision }}` for this repo.

What the Applications deploy lives elsewhere in the repo:

- `system/<component>/`: shared cluster components. `values.yaml` holds the Helm values; plain manifests sit next to it, or in `manifests/` when the component also has Helm values (`kube-prometheus-stack`, `sealed-secrets`).
- `helm/orders-gateway/`: the app's chart. `cd/orders-gateway/`: what each environment runs (`values.yaml` shared, then `dev.yaml`, `staging.yaml`, `prod.yaml`).
- `alerts/` and `policies/`: PrometheusRules and Kyverno policies, kept at the top level next to their tests.

Each Application carries `argocd.argoproj.io/manifest-generate-paths`: the folders and files it renders from (`/system/<component>`; for orders-gateway, the chart plus `values.yaml` and its env file). With a Git webhook, Argo CD then skips re-rendering Applications whose paths a commit didn't touch. Locally Argo CD polls rather than taking webhooks, so the gain there is small; it matters with many Applications and a webhook, as in production.

Sync waves: -10 CRDs, 0 Argo CD, 10 controllers, 20 observability, 30 policies, 40 apps. Waves wait for each child to be Healthy (Application health check in `system/argocd/values.yaml`).

| Application | Wave | What |
| --- | --- | --- |
| `prometheus-operator-crds` | -10 | Prometheus Operator CRDs |
| `argocd` | 0 | Argo CD, managing itself |
| `traefik` | 10 | Ingress controller: 2 replicas + PDB, plain HTTP, one entrypoint per host port (`system/traefik/values.yaml`) |
| `metrics-server` | 10 | CPU/memory metrics for HPAs and `kubectl top` |
| `kube-prometheus-stack` | 20 | Prometheus, Alertmanager, Grafana, exporters |
| `loki` | 20 | Loki, single binary |
| `alloy` | 20 | Log collection DaemonSet |
| `platform-alerts` | 25 | PrometheusRules from `alerts/` |
| `edge` | 25 | Ingresses for Argo CD (:8081), Grafana (:3000), Prometheus (:9090) and Alertmanager (:9093) (`system/edge/`) |
| `apps` (ApplicationSet) → `<app>-dev`, `-staging`, `-prod` | 40 | Each app per environment, from `cd/<app>/<env>.yaml`: the chart of the version it pins from the in-stack registry (or `helm/<app>` from Git for a dev-only build) + `cd/<app>/values.yaml` + `<env>.yaml`. auto-sync per env file (`autoSync`; by default dev on, staging and prod off: Sync in Argo CD, or `./pipeline cd --sync`) |
