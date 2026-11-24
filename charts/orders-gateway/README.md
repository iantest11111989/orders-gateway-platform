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
| `rollout.yaml`, `analysistemplate.yaml`, stable/canary Services | `rollout.enabled` | Canary with Argo Rollouts (prod). See below. |

## Canary (`rollout.enabled`)

The **Deployment stays the source of truth** (image, probes, resources, security). A `Rollout` points at it with `workloadRef`. Once the Rollout's own pods are up, it **scales the Deployment to zero and runs the pods itself**, so `kubectl get deploy` shows `0/0` in prod. That's expected. The HPA then targets the Rollout.

Every image change in prod becomes a canary. Argo Rollouts' Gateway API plugin moves traffic by changing the HTTPRoute's backend weights (`-stable` / `-canary` Services): 10% → analysis → 25% → analysis → 50% → analysis → 100% (after the last step Rollouts moves to 100% on its own). Each analysis (`AnalysisTemplate` `orders-gateway-slo`) asks Prometheus, about the canary pods only (`rollouts_pod_template_hash`), for:

- the 5xx ratio of `POST /orders`, which must be ≤ 0.5%
- the p99 latency, which must be ≤ 300 ms

Each waits 60 s for data, then is checked every 30 s, 4 times per step. A second failure aborts the rollout and sends all traffic back to stable. With no canary traffic, the measurements are Inconclusive, and a second one pauses the rollout until someone promotes or aborts it, which is why the demos run k6. Start the load before pushing a new prod image; otherwise the canary pauses at 10% and looks stuck.

Watch or drive it from `./platform shell`, or read-only at https://rollouts.localtest.me:

```sh
kubectl argo rollouts get rollout orders-gateway -n orders-prod --watch
kubectl argo rollouts promote orders-gateway -n orders-prod   # skip the current step
kubectl argo rollouts abort orders-gateway -n orders-prod
```

## Image

`image.tag` is required: a `sha-<12>` tag that CI publishes from `main`, or a demo tag (`v1`, `v2`, `v2-bad`). Set `image.digest` (`sha256:...`) to pin exactly what runs: the pod then uses `repository@digest`, and the tag stays as the version label and `APP_VERSION`.

## Test

```sh
./platform shell
helm lint charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
helm template orders-gateway charts/orders-gateway -f environments/prod/values.yaml --set image.tag=v1
```
