# apps/orders-gateway/chart

The Helm chart for [`apps/orders-gateway/app/`](../app/README.md). Every object is named after the Helm release, which Argo CD sets to the app's name. Each environment installs it with `apps/orders-gateway/cd/values.yaml` plus its own env file, through the ApplicationSet in `stack/delivery/bootstrap/apps/templates/apps.yaml`.

## How the app behaves, and what the chart does about it

Read [`server.js`](../app/server.js) first: about 100 lines. Each row is something it does and the setting that handles it.

| What `server.js` does | What could go wrong | The chart's answer | Where |
| --- | --- | --- | --- |
| Answers `/readyz` with 503 for 3 s after start (`STARTUP_DELAY_MS`) | Traffic reaches a pod that isn't ready | A startup probe on `/healthz` (up to 30 s), then a readiness probe on `/readyz` every 2 s. Traffic goes only to Ready pods | `templates/deployment.yaml` |
| Runs one event loop. `/work?ms=N` blocks it for N ms | A busy pod misses probes and gets killed while it's working | A lenient liveness probe: 6 misses, 10 s apart, so it restarts only a pod stuck for a minute | `templates/deployment.yaml` |
| The same: CPU-bound on one core | A CPU limit throttles the event loop even on an idle node, so latency spikes | A CPU request of 100m and no CPU limit. The HPA scales on that request | `values.yaml` `resources` |
| Small, steady memory | A leak takes the node down with it | Memory request 48Mi, limit 128Mi: a leaking pod is restarted alone | `values.yaml` `resources` |
| On SIGTERM: `/readyz` turns 503, it stops accepting connections, finishes in-flight requests, and exits within 25 s | Traefik still sends requests to a pod that has stopped listening | A `preStop` sleep of 5 s, so Traefik drops the pod first. Then the app drains. `terminationGracePeriodSeconds: 35` covers 5 + 25 s with a margin | `templates/deployment.yaml`, `values.yaml` |
| Starts in 3 s and is stateless | A release drops capacity, or a bad version takes every pod | Rolling updates with `maxSurge: 1` and `maxUnavailable: 0`: a new pod must be Ready before an old one stops. A version that never gets Ready stalls the rollout with the old pods still serving | `templates/deployment.yaml` |
| One pod is one point of failure | A node drain or upgrade evicts several pods at once | A PodDisruptionBudget (`maxUnavailable: 1`): evictions take one pod at a time. Pods spread across zones and nodes, so losing one node doesn't take them all | `templates/pdb.yaml`, `topologySpread` |
| CPU grows with traffic | A traffic spike saturates the pods | An HPA at 70% of the CPU request: 3 to 6 pods in prod, 2 to 4 in staging | `templates/hpa.yaml`, `cd/<env>.yaml` |
| Needs no root, no writes to disk and no Kubernetes API | A compromised pod gets a foothold | Non-root, read-only root filesystem, no capabilities, RuntimeDefault seccomp, no service account token. The namespaces enforce Pod Security `restricted` | `templates/deployment.yaml` |
| Is called only through Traefik and scraped by Prometheus, and calls nothing | A compromised pod reaches other services | A NetworkPolicy: in only from Traefik and Prometheus, out only to DNS | `templates/networkpolicy.yaml` |
| Reads its settings from environment variables. `/admin/fault` switches on failures with no auth | A fault switch reachable from the internet | Settings are chart values (`config.*`), turned into a ConfigMap. The Ingress refuses `/admin/*` with a 403 | `templates/configmap.yaml`, `templates/ingress.yaml` |
| Serves `/metrics` and labels unknown paths with their own `route` | A scanner creates thousands of metric series | A ServiceMonitor that keeps only the known routes | `templates/servicemonitor.yaml` |

The app needs no secrets. The platform's secrets are SealedSecrets ([`stack/security/sealed-secrets/`](../../../stack/security/sealed-secrets/)).

Per environment: dev runs 1 pod with no disruption budget or spreading. Staging and prod autoscale (2 to 4 and 3 to 6 pods) with both on. The differences are all in [`cd/<env>.yaml`](../cd/).

The demos check this under load, on prod: `release`, `chaos` (pod kill, node drain), `autoscale` and `platform-chaos` each fail if fewer than 99.5% of requests meet the SLO.

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
