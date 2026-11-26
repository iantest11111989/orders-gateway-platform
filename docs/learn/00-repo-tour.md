# 0. A tour of the repo

Time: about 2 hours, in sittings. You need Docker with 6 CPUs and 12 GB, and this repo.

Each section says where a part lives, how to see it, and why. Run commands from the repo root. `./platform shell` opens a shell with `kubectl`, `helm`, `argocd` and `k6`; inside it, drop the `./platform` prefix.

## 1. Start-up

Files: [`docker-compose.yml`](../../docker-compose.yml), [`scripts/compose-ready.sh`](../../scripts/compose-ready.sh), [`scripts/up.sh`](../../scripts/up.sh), [`cluster/kind.yaml`](../../cluster/kind.yaml), [`bootstrap/root.yaml`](../../bootstrap/root.yaml).

1. Start the stack and follow it:

   ```sh
   docker compose up -d --wait     # about 10 minutes the first time
   docker compose logs -f ready    # in a second terminal
   docker compose ps               # ready and step-1..4 all (healthy)
   ```

   One container, `ready`, does the work. It creates the kind cluster, installs Argo CD and hands it one root Application. Argo CD installs the rest. The `step-*` services only show progress.

2. Look at the nodes:

   ```sh
   ./platform kubectl get nodes -L topology.kubernetes.io/zone
   ```

   One control plane and two workers, each a Docker container capped at 2 CPU / 4 GiB, with the workers in different zones.

3. Open Argo CD at <http://localhost:8081>. Each tile is an Application from [`bootstrap/apps/templates/`](../../bootstrap/apps/templates/), installed in sync waves: CRDs, controllers, monitoring and policies, then the apps.

Check yourself: `traefik.yaml` is wave 10 and `edge.yaml` is wave 25. Why must Traefik come first?

## 2. What it exposes

Run `./platform verify`. It checks most of this in one go.

| Try it | Built in |
| --- | --- |
| `curl localhost:8080/version` returns 200 | [`ingress.yaml`](../../helm/orders-gateway/templates/ingress.yaml), [`system/traefik/values.yaml`](../../system/traefik/values.yaml) |
| `curl -X POST localhost:8080/admin/fault` returns 403 | the same, plus [`system/edge/`](../../system/edge/) |
| `./platform kubectl get deploy -A -l app.kubernetes.io/name=orders-gateway` shows dev, staging and prod | [`helm/orders-gateway/`](../../helm/orders-gateway/) |
| `docker compose stop && docker compose start`, then Grafana still shows the earlier traffic | the cluster runs in kind's own containers, outside Compose |

`/admin` is blocked at the edge by a deny-all middleware. The app itself has no auth on it, so it still works from inside the cluster.

Check yourself: [`scripts/ready-check.sh`](../../scripts/ready-check.sh) checks every Application only until it first passes, then only prod. Why? (Hint: what happens during a demo?)

## 3. Running the app well

Files: [`apps/orders-gateway/server.js`](../../apps/orders-gateway/server.js), [`helm/orders-gateway/values.yaml`](../../helm/orders-gateway/values.yaml), [`templates/deployment.yaml`](../../helm/orders-gateway/templates/deployment.yaml).

1. Read `server.js` (about 100 lines). Find the 3-second warm-up before `/readyz` returns 200, and the SIGTERM handler that drains and exits within 25 s.
2. Match each behaviour to the chart:

   | App | Chart |
   | --- | --- |
   | Not ready for 3 s | `startupProbe` on `/healthz`, then `readinessProbe` on `/readyz` |
   | Drains for up to 25 s on SIGTERM | `preStop` sleep 5 s, `terminationGracePeriodSeconds: 35` |
   | One event loop; `/work` burns CPU | CPU request 100m, no CPU limit, HPA at 70% |
   | Small, steady memory | request 48Mi, limit 128Mi |

3. See it live:

   ```sh
   ./platform kubectl -n prod get deploy,hpa,pdb,networkpolicy
   ```

The preStop sleep lets Traefik stop sending to a pod before it stops accepting. A CPU limit would throttle the event loop even on an idle node.

Check yourself: if the app took 40 s to exit, what would you change, and what breaks if you don't?

## 4. Environments, release and rollback

Files: [`cd/orders-gateway/`](../../cd/orders-gateway/), [`pipeline`](../../pipeline).

1. Diff the environments: `diff cd/orders-gateway/dev.yaml cd/orders-gateway/prod.yaml`. That diff is the whole difference between dev and prod.
2. In one terminal, send traffic to dev:

   ```sh
   while true; do curl -s -o /dev/null -w '%{http_code} ' 'http://localhost:8082/work?ms=20'; sleep 0.2; done
   ```

3. In another, build and deploy a dev-only version, then roll it back:

   ```sh
   ./pipeline ci orders-gateway          # test, build, scan, publish a local-<time> build
   ./pipeline cd orders-gateway dev      # point cd/orders-gateway/dev.yaml at it
   curl localhost:8082/version
   ./pipeline rollback orders-gateway dev
   ```

The first terminal should show only `200`. Watch Grafana, dashboard orders-gateway, panel Pods by version.

A release is a change to `cd/orders-gateway/<env>.yaml`, pushed to the in-stack Git server; Argo CD rolls it out. dev syncs by itself. For staging and prod, add `--sync` or click Sync in Argo CD.

Check yourself: after `./pipeline cd`, what does `git diff cd/orders-gateway/dev.yaml` show?

## 5. GitOps and CI

Files: [`system/git-server/`](../../system/git-server/), [`.github/workflows/`](../../.github/workflows/). Exercise [5](05-k8s-operations.md) goes deeper.

```sh
./platform kubectl -n dev scale deploy orders-gateway --replicas=3
./platform kubectl -n dev get deploy orders-gateway -w    # back to 1 within seconds
```

Argo CD reads from a Git server inside the cluster that holds a snapshot of your checkout. CI/CD runs locally through `./pipeline`; GitHub only checks pull requests. [`docs/production.md`](../production.md) describes how it would run in production.

Check yourself: which policy in [`policies/`](../../policies/) stops an unsigned image in prod? Why are `./pipeline`'s unsigned `localhost:30500/` images still admitted? (Read `verify-image-signatures.yaml`.)

## 6. Observability

This is the biggest part. Do exercises 1 to 4 here.

| Topic | Exercise |
| --- | --- |
| Metrics, counters and histograms, cardinality | [1. Prometheus](01-prometheus.md) |
| Dashboards as code | [2. Grafana](02-grafana.md), [`dashboards/`](../../dashboards/README.md) |
| JSON logs, following one request | [3. Loki](03-loki.md) |
| SLOs, burn rates, runbooks | [4. SLOs](04-slos.md), [`alerts/`](../../alerts/README.md), [`runbooks/`](../../runbooks/README.md) |

Then look at:

- Grafana, dashboard platform-overview, for cluster and node metrics.
- Alertmanager <http://localhost:9093>. On a quiet system only Watchdog fires; it always fires, to prove alerts get through.
- Alert delivery in Loki: `{namespace="monitoring", app="alert-receiver"} | json`.

## 7. Under load and failure

Open Grafana's orders-gateway dashboard with environment `demo`, then run the demos (each is a folder in [`demo/`](../../demo/README.md)). Each runs in namespace `demo`, a copy of prod or dev, and fails if fewer than 99.5% of k6's requests meet the SLO.

```sh
./platform demo rolling-update   # a release under load       (~2 min)
./platform demo chaos            # kill a pod, drain a node   (~3 min)
./platform demo autoscale        # HPA 3 → 6 → 3              (~8 min)
./platform demo gitops-revert    # a bad commit, git revert   (~5 min)
```

Then, with the curl loop from section 4 pointed at prod (`:8080`), kill platform components:

```sh
./platform kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
./platform kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana
./platform kubectl -n kyverno delete pod --all
```

Prod keeps serving. Requests go Traefik to pod, and none of these sit on that path. Kyverno fails open, so its outage can't block a rollback.

Check yourself: during `chaos`, why does the second eviction wait? Which object refuses it?

## 8. Pinned versions

Tool versions are in [`toolbox/versions.env`](../../toolbox/versions.env) and chart versions in `bootstrap/apps/templates/`. Renovate keeps them current.

## Next

- Exercises [1](01-prometheus.md) to [5](05-k8s-operations.md), if you skipped them.
- [`runbooks/`](../../runbooks/README.md): one per alert.
- [`docs/production.md`](../production.md): what would change in production.
