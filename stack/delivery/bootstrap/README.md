# bootstrap

Everything Argo CD installs, as an app of apps. One root Application renders one child Application per component.

- `root.yaml` is the root Application. `./platform up` applies it, pointed at the in-cluster Git server.
- `apps/` is a Helm chart. Each template is one Argo CD Application, and each uses `{{ .Values.repo.url }}` and `{{ .Values.repo.revision }}` for this repo.

The things the Applications deploy live elsewhere:

- `stack/<group>/<component>/` (groups: observability, security, delivery, networking): cluster components. Helm values are in `values.yaml`, with plain manifests next to it (or in `manifests/` for `prometheus` and `sealed-secrets`).
- `apps/<app>/chart/` and `apps/<app>/cd/`: each app's chart and what each environment runs.
- `stack/observability/alerts/` and `stack/security/kyverno/policies/`: alert rules and Kyverno policies, next to their tests.

## Sync waves

Applications start in waves. A wave waits until every Application in the one before is Healthy (the health check is in `stack/delivery/argocd/values.yaml`).

| Wave | Applications |
| --- | --- |
| -10 | `prometheus-operator-crds` |
| 0 | `argocd`, which manages itself |
| 10 | `traefik` (the Ingress controller, 2 replicas), `metrics-server`, `sealed-secrets` |
| 20 | `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana), `loki`, `alloy` (log collection), `kyverno`, `trivy-operator` |
| 25 | `platform-alerts` (rules from `stack/observability/alerts/`), `edge` (Ingresses for Argo CD, Grafana, Prometheus, Alertmanager) |
| 30 | `kyverno-policies` (from `stack/security/kyverno/policies/`), `network-policies` (default-deny for platform namespaces) |
| 40 | `apps`, an ApplicationSet: one `<app>-<env>` Application per env file in `apps/<app>/cd/` |
| 45 | `trickle`, a light stream of requests to every environment so the dashboards show live traffic |

Each app Application installs the chart version its env file pins, from the in-cluster registry, with `apps/<app>/cd/values.yaml` and the env file on top. A dev-only build without a version uses `apps/<app>/chart/` from Git instead. Auto-sync follows `autoSync` in the env file: on for dev, off for staging and prod.

## Render paths

Each Application sets `argocd.argoproj.io/manifest-generate-paths` to the folders it renders from. With a Git webhook, Argo CD then skips Applications a commit didn't touch. Locally Argo CD polls instead, so this matters mostly in production.
