# charts/orders-gateway

Helm chart for `orders-gateway` (the app in `app/`). Each environment installs it with its own values file from `environments/`, through an Argo CD Application (`gitops/apps/templates/orders-gateway-<env>.yaml`).

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

## Releases

A new image is a rolling update of the Deployment: one extra pod comes up (`maxSurge: 1`), and an old one stops only once the new one is ready (`maxUnavailable: 0`), so capacity never drops. Pods get a 5 s `preStop` pause so the gateway stops sending them traffic before they shut down. To undo a release, put the previous image back in Git (`./platform rollback`, or a revert of the promotion commit) and Argo CD rolls back the same way.

## Image

`image.tag` is required: a `sha-<12>` tag that CI publishes from `main`, or a demo tag (`v1`, `v2`). Set `image.digest` (`sha256:...`) to pin exactly what runs: the pod then uses `repository@digest`, and the tag stays as the version label and `APP_VERSION`.

## Test

```sh
./platform shell
helm lint charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
helm template orders-gateway charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
```
