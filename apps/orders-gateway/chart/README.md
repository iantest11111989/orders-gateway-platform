# apps/orders-gateway/chart

The Helm chart for [`apps/orders-gateway/app/`](../app/README.md). Every object is named after the Helm release, which Argo CD sets to the app's name. Each environment installs it with `apps/orders-gateway/cd/values.yaml` plus its own env file, through the ApplicationSet in `stack/delivery/bootstrap/apps/templates/apps.yaml`.

## Templates

| Template | When | What |
| --- | --- | --- |
| `deployment.yaml` | always | The workload, with startup, liveness and readiness probes. Non-root, read-only root filesystem, no capabilities, RuntimeDefault seccomp, no service account token. |
| `configmap.yaml` | always | App settings as environment variables (`config.*`). `FAULT_*` only when set. |
| `service.yaml`, `serviceaccount.yaml` | always | A ClusterIP Service on port 80, and an identity with no API token. |
| `ingress.yaml` | `ingress.enabled` | Ingresses (class `traefik`) for `ingress.hosts` and, with `ingress.default`, plain `localhost`, on the environment's port. `/admin/*` gets a 403. |
| `servicemonitor.yaml` | `serviceMonitor.enabled` | Lets Prometheus scrape `/metrics`. The SLO rules live in `stack/observability/alerts/`. |
| `networkpolicy.yaml` | `networkPolicy.enabled` | Traffic in only from Traefik and Prometheus; out only to DNS. |
| `hpa.yaml` | `autoscaling.enabled` | Scales on CPU, at 70% of the 100m request. |
| `pdb.yaml` | `podDisruptionBudget.enabled` | At most one pod down during a drain. |
| in the Deployment | `topologySpread.enabled` | Spreads pods across zones and nodes. |

## Releases and shutdown

A new image is a rolling update. One extra pod starts (`maxSurge: 1`), and an old pod stops only when the new one is ready (`maxUnavailable: 0`), so capacity never drops.

When a pod stops, `preStop` waits 5 s so Traefik stops sending it traffic first. The app then has up to 25 s to finish its requests. `terminationGracePeriodSeconds: 35` covers both, with a margin.

The liveness probe is lenient (6 misses, 10 s apart), because a `/work` call blocks the event loop. There is a memory limit but no CPU limit, which would only throttle.

To undo a release, put the previous version back in Git with `./pipeline rollback`.

## Image

`image.tag` is required. The env files set it to the version they run. `image.digest` (`sha256:...`) pins exactly what runs: the pod then uses `repository@digest`, and the tag stays as the version label. `./pipeline cd` writes the digest.

## Test

```sh
./platform shell
helm lint apps/orders-gateway/chart -f apps/orders-gateway/cd/prod.yaml --set image.tag=v1
helm template orders-gateway apps/orders-gateway/chart -f apps/orders-gateway/cd/prod.yaml --set image.tag=v1
```
