# 0. The work test, element by element

**Time:** about 2–3 hours, in sittings. **You need:** Docker with 6 CPUs and 12 GB for it, and this repo.

This tour walks the assignment ([the DevOps work test](#the-assignment-in-one-paragraph)) from top to bottom. For every element it says **what's asked**, **where it lives** in the repo, **how to see it** on your own running stack, and **the idea to understand**, with a question to check yourself. Where a deeper exercise exists (1–5 in this folder), it points there.

Run every command from the repo root. `./platform shell` opens a shell with `kubectl`, `helm`, `argocd`, `k6` and the rest already pointed at the cluster; inside it, drop the `./platform` prefix.

## The assignment in one paragraph

A team owns a stateless HTTP service, `orders-gateway` (`app/`). Build the platform around it: a local "cluster in a box" started by `docker compose up -d --wait`, in which Kubernetes runs the app in dev, staging and prod, ships and rolls it back, observes it, and keeps it up under stress. A fixed contract (ports, names, logins) lets the reviewer test it without reading the code. Items are labelled **[core]**, **[stretch]** or **[optional]**, and the README must say what was skipped and why.

---

## Part A: What you submit

### A1. One command starts everything

**Asked:** a `docker-compose.yml` at the root; `docker compose up -d --wait` is all it takes. On a fresh 8 vCPU / 16 GB VM, fitting in **6 CPU / 12 GB**, healthy in **under 15 minutes**.

**Where:** [`docker-compose.yml`](../../docker-compose.yml) (read the comment at the top), [`scripts/compose-ready.sh`](../../scripts/compose-ready.sh), [`scripts/up.sh`](../../scripts/up.sh), [decision 0026](../decisions/0026-compose-entrypoint.md).

**See it:**

```sh
time docker compose up -d --wait     # 10–15 min the first time, mostly image pulls
docker compose logs -f ready         # in a second terminal: every step as it happens
docker compose ps                    # ready and step-1..4, all (healthy)
```

**Understand:** one Compose container does the work: `ready`, built from the toolbox image (every tool pinned). It creates the kind cluster, installs Argo CD and gives it the root Application; Argo CD installs everything else. Compose doesn't run Kubernetes itself, it only starts the thing that does. `--wait` returns when `ready`'s healthcheck passes.

**Check yourself:** only `ready` does any work; the four `step-*` services just show progress (read [`scripts/compose-step.sh`](../../scripts/compose-step.sh)). Why does Compose need so few services when the stack has dozens of components?

### A2. The cluster: why kind

**Asked:** run the interesting part inside Kubernetes started by Compose; kind or k3d recommended; **justify the choice**.

**Where:** [`cluster/kind.yaml`](../../cluster/kind.yaml), [decision 0004](../decisions/0004-toolbox-and-cluster.md), README → *Key decisions and trade-offs*.

**See it:**

```sh
kubectl --kubeconfig out/kubeconfig.yaml get nodes -L topology.kubernetes.io/zone
docker ps --filter name=control-plane --filter name=worker    # the nodes are Docker containers
```

**Understand:** 1 control plane + 2 workers, each container capped at 2 CPU / 4 GiB (that's how the 6 / 12 budget is enforced). The two workers carry different zone labels, so disruption budgets, drains and topology spread behave as in a real multi-zone cluster. kind is upstream Kubernetes, the same thing Kubernetes' own CI uses; k3s (inside k3d) swaps in its own pieces.

**Check yourself:** what would a single-node cluster make impossible to demonstrate?

### A3. Installed declaratively, automatically

**Asked:** everything in the cluster installed with **Helm or Kustomize**, by the bootstrap, not ad-hoc `kubectl apply`.

**Where:** [`gitops/root.yaml`](../../gitops/root.yaml) → [`gitops/apps/templates/`](../../gitops/apps/templates/) (one Argo CD Application per component, each a Helm chart with values in [`gitops/values/`](../../gitops/values/)), [decision 0005](../decisions/0005-gitops-layout.md).

**See it:** open Argo CD at <http://localhost:8081> (`admin` / `admin12345`), or:

```sh
./platform kubectl -n argocd get applications
```

**Understand:** the bootstrap applies only what has to exist before Argo CD can work: the demo Sealed Secrets key, the in-stack Git server (with Kustomize, since Argo CD reads from it), Argo CD itself (with Helm) and one root Application. Everything else is an Application in Git, applied in **sync waves** (CRDs, then controllers, then observability, policies and the gateway, then the apps). Argo CD even manages itself.

**Check yourself:** open `gitops/apps/templates/` and compare the `sync-wave` annotations of `cert-manager.yaml` and `platform-gateway.yaml`. Why must cert-manager be running before the Gateway and its certificate are created?

---

## Part B: The fixed contract

`./platform verify` checks most of this table in one go. Run it first, then go row by row.

| Row | Try it | Where it's built |
| --- | --- | --- |
| **Readiness**: a service `ready`, healthy only when the platform is installed and the app serves | `docker compose ps` | [`scripts/ready-check.sh`](../../scripts/ready-check.sh): until it first passes, every Argo CD Application must be Synced and Healthy and prod's `/readyz` must answer; after that only prod's `/readyz` |
| **Kubeconfig** at `./out/kubeconfig.yaml` | `kubectl --kubeconfig out/kubeconfig.yaml get pods -A` | `scripts/up.sh` |
| **Namespaces**: dev, staging, prod, each a Deployment `app` labelled `app.kubernetes.io/name=app` | `kubectl --kubeconfig out/kubeconfig.yaml get deploy -A -l app.kubernetes.io/name=app` | [`charts/orders-gateway/`](../../charts/orders-gateway/) |
| **App endpoint**: prod at `http://localhost:8080`, `/admin/*` not reachable from outside | `curl localhost:8080/version` → 200; `curl -X POST localhost:8080/admin/fault` → 403 | [`httproute-public.yaml`](../../charts/orders-gateway/templates/httproute-public.yaml), [`httproutefilter.yaml`](../../charts/orders-gateway/templates/httproutefilter.yaml), [decision 0028](../decisions/0028-contract-ports-on-the-gateway.md) |
| **Logins**: admin / admin12345 | Grafana <http://localhost:3000>, Argo CD <http://localhost:8081> | [`gitops/values/argocd.yaml`](../../gitops/values/argocd.yaml) (a bcrypt hash), Grafana's SealedSecret |
| **Dashboards**: Grafana :3000, Prometheus :9090, Alertmanager :9093 | open each | [`cluster/kind.yaml`](../../cluster/kind.yaml) port mappings → the gateway |
| **Persistence and restarts** | `docker compose stop && docker compose start`, then check Grafana still has its history | `restart: unless-stopped` in `docker-compose.yml`; volumes for Prometheus, Loki and the Git server |

**Understand, row by row:**

- **Ingress vs Gateway.** The contract says "Ingress". This repo uses **Gateway API** (the successor to the Ingress resource) with Envoy Gateway, so `kubectl get ingress` is empty, on purpose. Decision 0028 explains why: the same edge serves every port, and a per-path filter answers `/admin/*` with 403 before it reaches the app.
- **`/admin` is blocked at the edge, not in the app.** The app has no auth on `/admin/fault`. A NetworkPolicy can't filter by path, so the gateway does. From inside the cluster it still works, and you'll use that in exercise 4 to break the app on purpose.
- **Persistence:** the cluster lives *outside* Compose (kind creates its own node containers). `docker compose stop` only stops `ready`, so the cluster and its data keep running.

**Check yourself:** why does `ready-check.sh` stop checking every Argo CD Application after the first success? (Hint: what happens during a demo?)

---

## Part C: The requirements

### C1. Kubernetes workloads [core]

**Asked:** a Helm chart or Kustomize (justify it), run "the way you'd want it run at 3am": resources, probes, rollout and shutdown, disruption budgets, autoscaling, security context, network policy, config and secrets. **Read `app/server.js`** to see how it starts, becomes ready, handles SIGTERM and exposes metrics.

**Where:** [`app/server.js`](../../app/server.js) first, then [`charts/orders-gateway/values.yaml`](../../charts/orders-gateway/values.yaml) and [`templates/deployment.yaml`](../../charts/orders-gateway/templates/deployment.yaml), README → *Operating under stress*.

**Do this in order:**

1. **Read the app** (100 lines). Find: the 3-second warm-up before `/readyz` says 200; the SIGTERM handler (stops accepting, drains, hard-exits after **25 s**); the metrics it writes by hand; `/admin/fault`.
2. **Match each behaviour to the chart:**

   | App behaviour | Chart setting |
   | --- | --- |
   | Not ready for 3 s after start | `startupProbe` (`/healthz`, every 1 s, up to 30), then `readinessProbe` (`/readyz`, every 2 s) |
   | Drains on SIGTERM, hard exit at 25 s | `preStop` sleep 5 s, `terminationGracePeriodSeconds: 35` (= 5 + 25 + 5 margin) |
   | One event loop; `/work` burns CPU | CPU request 100m, **no CPU limit**, HPA at 70% of the request |
   | Small and steady memory | request 48Mi, limit 128Mi |

3. **See them live:**

   ```sh
   ./platform shell
   kubectl -n prod get deploy,hpa,pdb,networkpolicy
   kubectl -n prod get pod -l app.kubernetes.io/name=app -o yaml | grep -A8 securityContext
   ```

**Understand:**

- **Why preStop sleeps.** When a pod is deleted, Kubernetes sends SIGTERM *and* removes it from the endpoints at the same time; the gateway learns a moment later. Without the 5 s sleep the app would stop accepting while the gateway is still sending to it: failed requests on every release.
- **Why no CPU limit.** A limit throttles the event loop even when the node has spare CPU, which shows up as latency. The request still reserves CPU and is what the HPA scales on.
- **Why Helm, not Kustomize.** "Turn on HPA, PDB and the public route only in prod" is a conditional; Helm expresses it in values, Kustomize would need patches per environment. [Decision 0009](../decisions/0009-chart-and-environments.md).
- **Security:** non-root (uid 1000), read-only root filesystem, every capability dropped, no service-account token, Pod Security `restricted`. NetworkPolicy: ingress only from the gateway and Prometheus, egress only to DNS ([decision 0017](../decisions/0017-network-policies.md)).

**Check yourself:** if the app's hard exit were 40 s instead of 25 s, what would you change, and what goes wrong if you don't?

### C2. Environments, release and rollback [core]

**Asked:** dev, staging and prod differ by values files or overlays, not copies. Bootstrap with no manual steps; re-running is safe. **One documented way to ship a new version and one to roll it back, while traffic flows.** No plaintext secrets; use something sensible and say why.

**Where:** [`environments/`](../../environments/), README → *Ship a new version, roll it back*, [`scripts/ship.sh`](../../scripts/ship.sh), [decision 0030](../decisions/0030-ship-and-rollback.md), [decision 0018](../decisions/0018-sealed-secrets.md).

**Do it** (this is exactly what the reviewer will do):

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

- **The environments:** diff `environments/dev/values.yaml` against `environments/prod/values.yaml`. That diff *is* the difference between dev and prod: replicas, HPA, PDB, spread, the `:8080` route.
- **Ship is a Git commit.** `ship` edits the image line in `environments/prod/values.yaml` and pushes your checkout to the Git server inside the cluster; Argo CD rolls it out. `kubectl set image` would be undone by Argo CD's self-heal within seconds.
- **No downtime** comes from C1: `maxUnavailable: 0`, readiness gating, preStop.
- **Secrets:** run `find gitops -name '*.sealed.yaml'` and open one. It's encrypted for the cluster's Sealed Secrets controller and safe in Git. The controller's key is a demo key committed on purpose so every clone works offline: **demo only**, and the README says so. `scripts/check-no-plain-secrets.sh` (CI) fails on any plain Secret.
- **Re-runnable:** run `./platform up` now, on the running stack. It changes nothing.

**Check yourself:** after a `rollback`, what does `git diff environments/prod/values.yaml` show, and why does it stay in your checkout?

### C3. GitOps and CI/CD [optional]

**Asked (GitOps):** Argo CD or Flux reconciling from a Git repo **your own stack hosts**, with self-heal and prune, and promotion by Git change.

**Where:** [`gitops/manifests/git-server/`](../../gitops/manifests/git-server/), [decision 0029](../decisions/0029-in-stack-git-server.md); exercise [5, step 1](05-k8s-operations.md).

**See it:**

```sh
./platform shell
kubectl -n dev scale deploy app --replicas=3
kubectl -n dev get deploy app -w            # back to 1 within seconds: self-heal
```

**Understand:** the Git server (soft-serve) runs inside the cluster. Argo CD reads from it; `ready`, `./platform up`, `ship` and `rollback` push to it. In GitHub mode (`REPO_URL=https://github.com/...`), Argo CD follows GitHub instead, promotions are pull requests, and the patch promoter merges soaked patch releases ([decision 0024](../decisions/0024-patch-promoter.md)).

**Asked (CI/CD):** workflows valid on real GitHub: lint and test, build, scan, push, update desired state. Bonus: least privilege, caching, PR vs main triggers, SBOM and signing, prod approvals.

**Where:** [`.github/workflows/`](../../.github/workflows/), README → *Environments, secrets, CI/CD and GitOps*. Read `ci-app.yml` (pull requests) and then `cd-app.yml` (merges to `main`) top to bottom: pull requests build and scan without pushing; `main` pushes, signs with cosign (no keys), attaches an SBOM, and commits the new image to dev.

**See it:** the repo's **Actions** tab on GitHub. The **CI · platform** workflow's **E2E · Fresh install** job runs `docker compose up -d --wait` on a fresh runner, ships and rolls back under traffic, and fails on a single non-200.

**Check yourself:** what stops an unsigned image from running in prod? (Find the Kyverno policy in `policies/`.) Then explain why `./platform ship`'s unsigned `localhost/orders-gateway:` builds are still admitted: look at `policies/restrict-image-registries.yaml` and [decision 0030](../decisions/0030-ship-and-rollback.md).

### C4. Observability [core]

**Asked:** metrics for the app, cluster and nodes; searchable logs with the app's JSON usable as is; dashboards as code (an on-call view answering "is it broken, where, since when" in 30 s, plus a cluster overview); SLOs for availability and latency with multi-window burn-rate alerts that are symptom-based, actionable and have runbooks; a quiet system has no alerts; routed through Alertmanager to a local receiver so delivery is observable. **[stretch]** tracing and correlation.

**This is the biggest section: do exercises 1–4 here.**

| Element | Exercise | Where |
| --- | --- | --- |
| Metrics, counters vs histograms, cardinality | [1. Prometheus](01-prometheus.md) | ServiceMonitor in the chart; [decision 0027](../decisions/0027-slis-for-the-node-app.md) |
| Dashboards as code, the 30-second view | [2. Grafana](02-grafana.md) | [`dashboards/`](../../dashboards/README.md), [decision 0023](../decisions/0023-dashboards-as-code.md) |
| JSON logs, searching, following one request | [3. Loki](03-loki.md) | Alloy → Loki ([decision 0007](../decisions/0007-observability-stack.md)) |
| SLOs, burn rates, runbooks, alert delivery | [4. SLOs](04-slos.md) | [`alerts/`](../../alerts/README.md), [`runbooks/`](../../runbooks/README.md) |

**Then check the remaining elements:**

- **Cluster and node metrics:** Grafana → **platform-overview**, and Prometheus → *Status → Targets*: node-exporter, kubelet, kube-state-metrics.
- **A quiet system, no alerts:** Alertmanager <http://localhost:9093> should show only **Watchdog**, an alert that always fires on purpose to prove the pipeline works.
- **Delivery is observable:** in Grafana → Explore → Loki: `{namespace="monitoring", app="alert-receiver"} | json`. Every alert Alertmanager delivers is logged there.
- **Tracing [stretch]: not done.** Exercise 3, step 4 shows what *is* there: the app logs a `trace_id` from a `traceparent` header, so one request can be followed across logs.

**Check yourself:** why does the latency SLO cover `/echo` and `/version` but not `/work`?

### C5. Operating it under stress [core]

**Asked:** stay available and reasonably fast through sharp traffic rises, rolling releases, and pods and platform components being killed. **They will test it.** Document what and why.

**Where:** README → *Operating under stress*; the demos (README → *Demos*, [`scripts/demo.sh`](../../scripts/demo.sh)). Each demo runs in `demo`, a copy of prod, never in prod itself ([decision 0020](../decisions/0020-demos-in-a-copy-of-prod.md)).

**Do it,** with Grafana's **orders-gateway** dashboard open (set the namespace to `demo`):

```sh
./platform demo rolling-update   # a release under load       (~2 min)
./platform demo chaos            # kill a pod, drain a node   (~3 min)
./platform demo autoscale        # 180 req/s: HPA 3 → 6 → 3   (~8 min)
./platform demo canary           # Argo Rollouts, SLO-gated   (~8 min)
./platform demo canary-fail      # a bad version, auto-abort  (~3 min)
```

Each one fails if fewer than 99.5% of k6's requests meet the SLO. Run `./platform budget --watch 600` in another terminal to see the CPU and memory peak.

**Then kill platform components yourself** and watch prod keep serving (keep the curl loop from C2 running):

```sh
./platform shell
kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana
kubectl -n kyverno delete pod --all
```

**Understand:** the app's path is gateway → pod. Prometheus, Loki, Grafana and Argo CD are off that path, so losing them doesn't drop requests. Kyverno's webhooks **fail open**, so its outage can't block a rollout or a rollback (the trade-off: policies aren't checked meanwhile). The one weak spot is the gateway's **single proxy replica**, listed under the README's limitations.

**Check yourself:** during `chaos`, why does the second eviction wait? Which object refuses it?

### C6. Documentation [core]

**Asked:** README for a new teammate: architecture diagram and key decisions/trade-offs; how to ship, roll back, debug; local vs real cloud and what you'd change (**[stretch]** Terraform); honest limitations and next steps.

**Where, and what to read:**

| Asked | README section |
| --- | --- |
| Architecture diagram, decisions and trade-offs | *Architecture*, *Key decisions and trade-offs*; then skim [`docs/decisions/`](../decisions/README.md) (31 short records) |
| Ship and roll back | *Ship a new version, roll it back* (you did it in C2) |
| Debug when it's broken | *When it's broken: how to debug* |
| Local vs cloud | *Local vs a real cloud (EKS/GKE)* |
| Terraform [stretch] | [`docs/terraform-sketch/`](../terraform-sketch/README.md): sketched, never applied |
| Limitations, next steps, skipped | *What we skipped and why* |

**Check yourself:** follow *When it's broken* for real. In a shell, break a copy of dev the way [exercise 4](04-slos.md) does, and see whether the README's five steps lead you to the cause.

---

## Part D: The rules

| Rule | How it's met | Check it |
| --- | --- | --- |
| Open-source tooling only, **pinned versions** | Every tool is pinned and checksum-verified in [`toolbox/versions.env`](../../toolbox/versions.env); every chart version and image digest is pinned in `gitops/`; Renovate keeps them current ([decision 0010](../decisions/0010-renovate.md)) | `grep -rn "targetRevision" gitops/apps/templates/ \| head` |
| Everything runs from the Compose file | `docker compose up -d --wait` is the whole start-up | A1 |
| Don't change the app's behaviour in `app/` | `server.js`, `package.json` and `server.test.js` are byte-identical to the originals; only configuration (environment variables) differs between environments. The Dockerfile is rewritten (allowed: "you may add files, for example a better Dockerfile") | `git log --oneline -- app/server.js` shows only the commit that added it |

---

## Where to go next

- Exercises [1](01-prometheus.md) → [5](05-k8s-operations.md), if you skipped them in C4.
- The 31 [decision records](../decisions/README.md): each is a page, with the context, the choice and what it costs.
- [`runbooks/`](../../runbooks/README.md): one per alert. Read the SLO ones; that's what an on-call engineer would open.
