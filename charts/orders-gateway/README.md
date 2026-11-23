# charts/orders-gateway

Helm chart for `orders-gateway` (the app in `app/`). Each environment installs it with its own values file from `environments/`, through an Argo CD Application (`gitops/apps/templates/orders-<env>.yaml`). See [decision 0009](../../docs/decisions/0009-chart-and-environments.md).

| Template | Always | What |
| --- | --- | --- |
| `deployment.yaml` | yes | The workload. Startup, liveness and readiness probes; non-root, read-only root filesystem, all capabilities dropped, RuntimeDefault seccomp; no service account token; 30 s grace for the app's 5 s drain + 20 s shutdown; zero-downtime rolling update. |
| `configmap.yaml` | yes | App settings as environment variables (`config.*`). `FAULT_*` only when set. |
| `service.yaml`, `serviceaccount.yaml` | yes | ClusterIP on port 80; an identity without an API token. |
| `httproute.yaml` | `route.enabled` | `https://<route.hostname>` on the shared Gateway. |
| `servicemonitor.yaml` | `serviceMonitor.enabled` | `/metrics` for Prometheus. The SLO rules are cluster-wide per namespace (`alerts/`), so there's no PrometheusRule here. |
| `networkpolicy.yaml` | `networkPolicy.enabled` | Ingress only from the gateway and Prometheus; egress only DNS. |
| `hpa.yaml` | `autoscaling.enabled` | CPU-based HorizontalPodAutoscaler (metrics-server). |
| `pdb.yaml` | `podDisruptionBudget.enabled` | At most one pod down during voluntary disruptions. |
| (in the Deployment) | `topologySpread.enabled` | Spread across zones and nodes. |

The Argo Rollouts `Rollout` (`workloadRef` to this Deployment) for the prod canary comes in its own PR.

## Image

`image.tag` is required: a `sha-<12>` tag that CI publishes from `main`, or a demo tag (`v1`, `v2`, `v2-bad`). Set `image.digest` (`sha256:...`) to pin exactly what runs: the pod then uses `repository@digest`, and the tag stays as the version label and `APP_VERSION`.

## Test

```sh
./platform shell
helm lint charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
helm template orders-gateway charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
```
