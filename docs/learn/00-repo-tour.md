# 0. A tour of the repo

**Time:** about 2 hours, in sittings. **You need:** Docker with 6 CPUs and 12 GB, and this repo.

This tour walks the platform from start-up to operations. For each part it says **where it lives**, **how to see it** on your running stack, and **the idea to understand**, with a question to check yourself. Where a deeper exercise exists (1–5 in this folder), it points there.

Run every command from the repo root. `./platform shell` opens a shell with `kubectl`, `helm`, `argocd`, `k6` and the rest pointed at the cluster; inside it, drop the `./platform` prefix.

---

## 1. Start-up

### One command starts everything

**Where:** [`docker-compose.yml`](../../docker-compose.yml) (read the comment at the top), [`scripts/compose-ready.sh`](../../scripts/compose-ready.sh), [`scripts/up.sh`](../../scripts/up.sh).

```sh
time docker compose up -d --wait     # about 10 minutes the first time, mostly image pulls
docker compose logs -f ready         # in a second terminal: every step as it happens
docker compose ps                    # ready and step-1..4, all (healthy)
```

**Understand:** one Compose container does the work: `ready`, built from the toolbox image (every tool pinned). It creates the kind cluster, installs Argo CD and gives it the root Application; Argo CD installs everything else. Compose doesn't run Kubernetes, it starts the thing that does.

**Check yourself:** the four `step-*` services only show progress (read [`scripts/compose-step.sh`](../../scripts/compose-step.sh)). Why does Compose need so few services when the stack has dozens of components?

### The cluster

**Where:** [`cluster/kind.yaml`](../../cluster/kind.yaml).

```sh
kubectl --kubeconfig out/kubeconfig.yaml get nodes -L topology.kubernetes.io/zone
docker ps --filter name=control-plane --filter name=worker    # the nodes are Docker containers
```

**Understand:** 1 control plane + 2 workers, each container capped at 2 CPU / 4 GiB, which is how the 6 / 12 budget is enforced. The two workers carry different zone labels, so disruption budgets, drains and spreading behave as in a multi-zone cluster.

**Check yourself:** what would a single-node cluster make impossible to show?

### Everything installed from Git

**Where:** [`gitops/root.yaml`](../../gitops/root.yaml) → [`gitops/apps/templates/`](../../gitops/apps/templates/) (one Argo CD Application per component, each a Helm chart with values in [`gitops/values/`](../../gitops/values/)).

Open Argo CD at <http://localhost:8081> (`admin` / `admin12345`), or `./platform kubectl -n argocd get applications`.

**Understand:** the bootstrap applies only what must exist before Argo CD can work: the demo Sealed Secrets key, the Git server, Argo CD itself and one root Application. Everything else is an Application in Git, applied in **sync waves**: CRDs, then controllers, then monitoring, policies and the gateway, then the apps. Argo CD manages itself too.

**Check yourself:** compare the `sync-wave` annotations of `cert-manager.yaml` and `platform-gateway.yaml`. Why must cert-manager run before the Gateway and its certificate are created?

---

## 2. What it exposes

`./platform verify` checks most of this in one go. Run it first.

| | Try it | Where it's built |
| --- | --- | --- |
| The `ready` health signal | `docker compose ps` | [`scripts/ready-check.sh`](../../scripts/ready-check.sh): until it first passes, every Argo CD Application must be Synced and Healthy and prod must answer; after that only prod |
| The kubeconfig | `kubectl --kubeconfig out/kubeconfig.yaml get pods -A` | `scripts/up.sh` |
| dev, staging, prod: a Deployment `app` in each | `kubectl --kubeconfig out/kubeconfig.yaml get deploy -A -l app.kubernetes.io/name=app` | [`charts/orders-gateway/`](../../charts/orders-gateway/) |
| prod on `:8080`, `/admin/*` refused | `curl localhost:8080/version` → 200; `curl -X POST localhost:8080/admin/fault` → 403 | [`httproute-public.yaml`](../../charts/orders-gateway/templates/httproute-public.yaml), [`httproutefilter.yaml`](../../charts/orders-gateway/templates/httproutefilter.yaml) |
| Logins | Grafana <http://localhost:3000>, Argo CD <http://localhost:8081> | [`gitops/values/argocd.yaml`](../../gitops/values/argocd.yaml) (a bcrypt hash), Grafana's SealedSecret |
| Prometheus :9090, Alertmanager :9093 | open each | [`cluster/kind.yaml`](../../cluster/kind.yaml) port mappings → the gateway |
| Restarts keep data | `docker compose stop && docker compose start`, then check Grafana still has its history | `restart: unless-stopped`; volumes for Prometheus, Loki and the Git server |

**Understand:**

- **Gateway API, not Ingress.** Envoy Gateway serves every port, so `kubectl get ingress` is empty on purpose. A per-path filter answers `/admin/*` with 403 before it reaches the app.
- **`/admin` is blocked at the edge, not in the app.** The app has no auth on `/admin/fault`, and a NetworkPolicy can't filter by path. From inside the cluster it still works; exercise 4 uses that to break the app on purpose.
- **Restarts:** the cluster lives *outside* Compose (kind creates its own node containers), so `docker compose stop` only stops `ready` and the cluster keeps running.

**Check yourself:** why does `ready-check.sh` stop checking every Application after the first success? (Hint: what happens during a demo?)

---

## 3. Running the app well

**Where:** [`app/server.js`](../../app/server.js) first, then [`charts/orders-gateway/values.yaml`](../../charts/orders-gateway/values.yaml) and [`templates/deployment.yaml`](../../charts/orders-gateway/templates/deployment.yaml).

1. **Read the app** (about 100 lines). Find the 3-second warm-up before `/readyz` says 200; the SIGTERM handler (stops accepting, drains, exits after **25 s**); the metrics it writes; `/admin/fault`.
2. **Match each behaviour to the chart:**

   | App behaviour | Chart setting |
   | --- | --- |
   | Not ready for 3 s after start | `startupProbe` (`/healthz`, every 1 s, up to 30), then `readinessProbe` (`/readyz`, every 2 s) |
   | Drains on SIGTERM, exits at 25 s | `preStop` sleep 5 s, `terminationGracePeriodSeconds: 35` (5 + 25 + 5 margin) |
   | One event loop; `/work` burns CPU | CPU request 100m, **no CPU limit**, HPA at 70% of the request |
   | Small, steady memory | request 48Mi, limit 128Mi |

3. **See them live:**

   ```sh
   ./platform shell
   kubectl -n prod get deploy,hpa,pdb,networkpolicy
   kubectl -n prod get pod -l app.kubernetes.io/name=app -o yaml | grep -A8 securityContext
   ```

**Understand:**

- **Why preStop sleeps.** When a pod is deleted, Kubernetes sends SIGTERM *and* removes it from the endpoints at the same time, and the gateway learns a moment later. Without the sleep the app would stop accepting while the gateway still sends to it.
- **Why no CPU limit.** A limit throttles the event loop even when the node has spare CPU, which shows up as latency. The request still reserves CPU and is what the HPA scales on.
- **Why Helm.** "HPA, disruption budget and public route only in prod" is a conditional, which Helm expresses in values.
- **Security:** non-root, read-only filesystem, every capability dropped, no service-account token, Pod Security `restricted`. NetworkPolicy: in only from the gateway and Prometheus, out only to DNS.

**Check yourself:** if the app's exit took 40 s instead of 25 s, what would you change, and what goes wrong if you don't?

---

## 4. Environments, ship and rollback

**Where:** [`environments/`](../../environments/), [`scripts/ship.sh`](../../scripts/ship.sh).

```sh
# terminal 1: traffic on prod the whole time
while true; do curl -s -o /dev/null -w '%{http_code} ' 'http://localhost:8080/work?ms=20'; sleep 0.2; done

# terminal 2
./platform ship            # build app/, load into kind, roll prod out
curl localhost:8080/version
./platform rollback        # back to the previous image
curl localhost:8080/version
```

Terminal 1 should show nothing but `200`. Watch it in Grafana → **orders-gateway** → **Pods by version**.

**Understand:**

- **The environments:** diff `environments/dev/values.yaml` against `environments/prod/values.yaml`. That diff *is* the difference between dev and prod.
- **Ship is a Git commit.** `ship` edits the image lines in `environments/prod/values.yaml` and pushes your checkout to the cluster's Git server; Argo CD rolls it out. `kubectl set image` would be undone by self-heal within seconds.
- **No downtime** comes from section 3: `maxUnavailable: 0`, readiness gating, preStop.
- **Secrets:** run `find gitops -name '*.sealed.yaml'` and open one. It's encrypted for the cluster's Sealed Secrets controller, so it's safe in Git. The controller's key is a demo key committed so every clone works offline: **demo only**. `scripts/check-no-plain-secrets.sh` (CI) fails on any plain Secret.
- **Re-runnable:** run `./platform up` on the running stack. It changes nothing.

**Check yourself:** after a `ship` and a `rollback`, what does `git diff environments/prod/values.yaml` show?

---

## 5. GitOps and CI/CD

**Where:** [`gitops/manifests/git-server/`](../../gitops/manifests/git-server/), [`.github/workflows/`](../../.github/workflows/); exercise [5, step 1](05-k8s-operations.md).

```sh
./platform shell
kubectl -n dev scale deploy app --replicas=3
kubectl -n dev get deploy app -w            # back to 1 within seconds: self-heal
```

**Understand:** the Git server (soft-serve) runs inside the cluster. Argo CD reads from it; `ready`, `./platform up`, `ship` and `rollback` push to it. With `REPO_URL=https://github.com/...`, Argo CD follows GitHub instead, promotions are pull requests, and the patch promoter merges patch releases once they've soaked.

Read `ci-app.yml` (pull requests) and then `cd-app.yml` (merges to `main`). Pull requests build and scan without pushing, smoke-test the image (`scripts/smoke-test-image.sh`, which you can run locally on any image) and hold a 60-second k6 run to the SLOs (`app/k6/perf-gate.js`). `main` pushes, signs with cosign (no keys), attaches an SBOM and commits the new image to dev. The **CI · platform** workflow's **E2E · Fresh install** job runs the whole start-up on a fresh runner and ships and rolls back under traffic.

**Check yourself:** what stops an unsigned image from running in prod? (Find the Kyverno policy in `policies/`.) Then explain why `./platform ship`'s unsigned `localhost/orders-gateway:` builds are still admitted: look at `policies/restrict-image-registries.yaml`.

---

## 6. Observability

**This is the biggest part: do exercises 1–4 here.**

| Topic | Exercise | Where |
| --- | --- | --- |
| Metrics, counters vs histograms, cardinality | [1. Prometheus](01-prometheus.md) | the ServiceMonitor in the chart |
| Dashboards as code, the 30-second view | [2. Grafana](02-grafana.md) | [`dashboards/`](../../dashboards/README.md) |
| JSON logs, searching, following one request | [3. Loki](03-loki.md) | Alloy → Loki |
| SLOs, burn rates, runbooks, alert delivery | [4. SLOs](04-slos.md) | [`alerts/`](../../alerts/README.md), [`runbooks/`](../../runbooks/README.md) |

Then check:

- **Cluster and node metrics:** Grafana → **platform-overview**, and Prometheus → *Status → Targets*.
- **A quiet system:** Alertmanager <http://localhost:9093> shows only **Watchdog**, which always fires to prove the pipeline works.
- **Delivery:** Grafana → Explore → Loki: `{namespace="monitoring", app="alert-receiver"} | json`.
- **Tracing: not done.** Exercise 3, step 4 shows what *is* there: a `trace_id` from a `traceparent` header, so one request can be followed across logs.

**Check yourself:** why does the latency SLO cover `/echo` and `/version` but not `/work`?

---

## 7. Under load and failure

**Where:** the README's *Under load and failure* and *Demos*, [`scripts/demo.sh`](../../scripts/demo.sh). Each demo runs in `demo`, a copy of prod, never in prod itself.

With Grafana's **orders-gateway** dashboard open (environment `demo`):

```sh
./platform demo rolling-update   # a release under load       (~2 min)
./platform demo chaos            # kill a pod, drain a node   (~3 min)
./platform demo autoscale        # HPA 3 → 6 → 3              (~8 min)
./platform demo canary           # Argo Rollouts, SLO-checked (~8 min)
./platform demo canary-fail      # a bad version, auto-abort  (~3 min)
```

Each fails if fewer than 99.5% of k6's requests meet the SLO. Run `./platform budget --watch 600` in another terminal to see the peak.

**Then kill platform components yourself** and watch prod keep serving (keep the curl loop from section 4 running):

```sh
./platform shell
kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana
kubectl -n kyverno delete pod --all
```

**Understand:** requests go gateway → pod. Prometheus, Loki, Grafana and Argo CD are off that path, so losing them drops nothing. Kyverno **fails open**, so its outage can't block a rollout or rollback (meanwhile, policies aren't checked). The weak spot is the gateway's **single proxy replica**, listed in the README's limitations.

**Check yourself:** during `chaos`, why does the second eviction wait? Which object refuses it?

---

## 8. Pinned and reproducible

| | How | Check it |
| --- | --- | --- |
| Every tool pinned | Versions and checksums in [`toolbox/versions.env`](../../toolbox/versions.env); chart versions and image digests in `gitops/`; Renovate keeps them current | `grep -rn "targetRevision" gitops/apps/templates/ \| head` |
| The app unchanged across environments | Only configuration (environment variables) differs between dev, staging and prod | `diff environments/dev/values.yaml environments/prod/values.yaml` |

---

## Where to go next

- Exercises [1](01-prometheus.md) → [5](05-k8s-operations.md), if you skipped them in section 6.
- [`runbooks/`](../../runbooks/README.md): one per alert. Read the SLO ones; that's what an on-call engineer opens.
- [`docs/production-on-aws.md`](../production-on-aws.md): how this would run on AWS for real.
