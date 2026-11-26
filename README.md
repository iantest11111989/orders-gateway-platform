# orders-gateway-platform

A local **"cluster in a box"**: one command starts a Kubernetes cluster that runs, ships, monitors and operates `orders-gateway`, a small Node.js service, the way a platform team would in production.

```sh
docker compose up -d --wait
```

That's all it takes. Compose's `ready` service creates a kind cluster and hands it to Argo CD, and Argo CD installs everything else from Git, with Helm, in order. `--wait` returns when the platform is installed and prod is serving, about 9 minutes from cold. While it runs, four progress services turn **Healthy** one by one:

```
 ✔ Container orders-gateway-platform-step-1-cluster-1    Healthy   (kind nodes Ready)
 ✔ Container orders-gateway-platform-step-2-argocd-1     Healthy   (Git server and Argo CD running)
 ⠿ Container orders-gateway-platform-step-3-platform-1   Waiting   (every platform component Synced and Healthy)
 ⠿ Container orders-gateway-platform-step-4-apps-1       Waiting   (dev, staging and prod Synced and Healthy)
 ⠿ Container orders-gateway-platform-ready-1             Waiting   (all of it, and prod serving on :8080)
```

To follow every detail as it happens: `docker compose logs -f ready`.

## What you get

| | Where | Check it |
| --- | --- | --- |
| The app in prod | `http://localhost:8080` (`/admin/*` is refused with 403) | `curl localhost:8080/version` |
| The app in dev and staging | `http://localhost:8082` (dev), `http://localhost:8083` (staging) | `curl localhost:8082/version` |
| Grafana | `http://localhost:3000`, `admin` / `admin12345` | the **orders-gateway** dashboard |
| Argo CD | `http://localhost:8081`, `admin` / `admin12345` | every app Synced and Healthy |
| Prometheus, Alertmanager | `http://localhost:9090`, `http://localhost:9093` | only **Watchdog** firing when healthy |
| kubectl | `./out/kubeconfig.yaml` | `kubectl --kubeconfig out/kubeconfig.yaml get pods -A` |
| A health signal | Compose service `ready` turns healthy when everything is installed and prod serves | `docker compose ps` |
| Survives restarts | `docker compose stop` / `start` keeps the cluster and its data | `docker compose stop && docker compose start` |
| Fits 6 CPU / 12 GB | each kind node is capped at 2 CPU / 4 GiB | `./platform budget` |

`./platform verify` checks all of it in one go.

## Quick start

**You need Docker, nothing else.** Every other tool (kind, kubectl, helm, kubeseal, cosign, k6, the argocd CLI, jq, yq) is pinned in a toolbox image that `./platform` runs for you.

| | Linux | Mac (Apple silicon) |
| --- | --- | --- |
| Machine | 8 vCPU / 16 GB, x86-64 | 16 GB |
| Docker | Docker Engine with the Compose plugin | Colima: `colima start --cpu 6 --memory 12`, plus `brew install docker-compose` |

```sh
git clone https://github.com/iantest11111989/orders-gateway-platform.git
cd orders-gateway-platform
docker compose up -d --wait
curl localhost:8080/version
```

Then open Grafana at <http://localhost:3000> and its **orders-gateway** dashboard.

`./platform` does everything after start-up:

```sh
./platform verify        # check apps, scrape targets, logs, ports and policies
./platform urls          # every URL and login
./platform budget        # CPU and memory against 6 CPU / 12 GiB
./platform ship          # ship apps/orders-gateway/ to prod; ./platform rollback undoes it
./platform demo chaos    # and the other demos below
./platform shell         # a shell with kubectl, helm, argocd, k6 pointed at the cluster
./platform down          # delete everything: the Compose services and the cluster
```

`./platform up` does the same as `docker compose up`, in the foreground. Both are safe to re-run.

> **Security note:** the `ready` container and the toolbox mount the Docker socket so kind can create its node containers. That's root-equivalent on the Docker host (normal for kind), so run it on a machine you control.

**Plain HTTP on local ports.** Everything is on `127.0.0.1`, through Traefik, one port each: prod `:8080`, dev `:8082`, staging `:8083`, the demo copy `:8084`, Argo CD `:8081`, Grafana `:3000`, Prometheus `:9090`, Alertmanager `:9093`. No hostnames, no certificates, nothing below port 1024. `./platform urls` lists them with the logins.

## How it works

```mermaid
flowchart LR
  you([You: docker compose up]) --> ready["Compose service <b>ready</b><br/>(toolbox: kind, helm, kubectl…)"]
  ready -->|creates| cluster
  ready -->|pushes this checkout| git
  ready -->|writes| kc[./out/kubeconfig.yaml]

  subgraph cluster [kind cluster: 1 control plane + 2 workers, capped at 6 CPU / 12 GiB]
    git[(Git server<br/>soft-serve)] -->|desired state| argocd[Argo CD<br/>app-of-apps, self-heal, prune]
    argocd -->|Helm, in sync waves| platform & envs
    subgraph envs [dev · staging · prod]
      app["Deployment <b>app</b><br/>HPA · PDB · NetworkPolicy"]
    end
    subgraph platform [Platform]
      gw[Traefik: Ingress]
      kyv[Kyverno: admission]
      ss[Sealed Secrets]
      trivy[Trivy Operator]
    end
    gw -->|"/admin/* → 403"| app
    prom[Prometheus] -->|scrapes| app
    alloy[Alloy] -->|pod logs| loki[Loki]
    prom --> am[Alertmanager] --> recv[alert-receiver] -->|logs| loki
    prom & loki --> graf[Grafana]
  end

  user([Browser, curl, k6]) -->|":8080 prod · :8082 dev · :8083 staging<br/>:3000 Grafana · :8081 Argo CD<br/>:9090 Prometheus · :9093 Alertmanager"| gw
  gh[(GitHub: CI builds, scans,<br/>signs; promotion PRs)] -.->|GitHub mode| argocd
```

- **Compose is only the outer shell.** Its `ready` service runs the toolbox, creates the kind cluster, installs Argo CD and hands it the root Application, then stays up as the health signal. The four `step-*` services do no work: their healthchecks show progress.
- **Git is the only way in.** Argo CD follows a Git server inside the cluster, which `ready` (and `./platform up`, `ship`, `rollback`) pushes this checkout to, with self-heal and prune on. Set `REPO_URL=https://github.com/...` to follow GitHub instead, where CI and promotion pull requests take over.
- **Argo CD installs everything with Helm,** itself included, in sync waves: CRDs, then controllers, then monitoring, policies and the UI Ingresses, then the apps.
- **One edge.** Traefik (2 replicas, a disruption budget) serves every port as a standard Kubernetes Ingress, and refuses `/admin/*` from outside with a 403.
- **Alerts you can see.** Alertmanager delivers to a small `alert-receiver` that logs each alert as JSON into Loki. The always-firing Watchdog proves the path works.

### Main choices

| Choice | Why | Instead of |
| --- | --- | --- |
| **kind**, 1 control plane + 2 workers, run from a toolbox container | Only Docker needed; upstream Kubernetes; two workers in two labelled zones make disruption budgets, drains and spreading real | k3d (k3s differs from upstream), minikube (built for one node) |
| **One Helm chart, a values file per environment** | The app needs conditionals (HPA and PDB only in some environments), which Helm expresses simply | Kustomize overlays |
| **Argo CD, app-of-apps, managing itself** | Everything comes from Git, sync waves give an ordered start-up, and its UI makes changes easy to follow | Flux (no UI) |
| **A Git server inside the cluster** (soft-serve) | Works offline with no GitHub token; `ship` and `rollback` are Git commits | Gitea (heavier) |
| **Traefik, with standard Ingresses** | The brief asks for an Ingress; Traefik is maintained, light, and its middleware does the `/admin` 403 | ingress-nginx (retired), Gateway API (below) |
| **kube-prometheus-stack, Loki, Alloy** | The common open-source stack, trimmed to fit 12 GB | Elastic, or a SaaS |
| **Burn-rate SLO alerts** | Page fast on real problems, stay quiet on blips | Plain error-rate thresholds |
| **Sealed Secrets** | Encrypted secrets live in Git and work offline. The key is committed so any clone can decrypt: **demo only** | External Secrets (needs a secret manager) |
| **Kyverno** | Policies as YAML next to the manifests, tested with `kyverno test` | OPA Gatekeeper (Rego) |
| **cosign keyless, Trivy, Renovate** | Signed images with SBOMs and no keys to manage; scans in CI and in the cluster; every pin kept current | |

**Why Ingress, not Gateway API.** Gateway API (with Envoy Gateway) was built and explored for this project, then set aside: it adds more moving parts than a single-service demo needs, and the brief asks for an Ingress. For a new production system we'd adopt it: role-based ownership, traffic splitting and portability are built into the standard.

## Ship a new version, roll it back

```sh
# Optional, in a second terminal: traffic on prod while you do it
while true; do curl -s -o /dev/null -w '%{http_code} ' 'http://localhost:8080/work?ms=20'; sleep 0.2; done

./platform ship            # build apps/orders-gateway/, load it into kind, roll prod out to it
./platform rollback        # back to the image prod ran before
```

`ship` builds `apps/orders-gateway/` as `localhost/orders-gateway:local-<timestamp>` (or `./platform ship <tag>`), loads it into the kind nodes, sets it in `cd/orders-gateway/prod.yaml` and pushes the checkout to the cluster's Git server. Argo CD then replaces prod's pods one at a time, never dropping below full capacity. `rollback` puts back the image prod ran before (a second `rollback` goes further back) and leaves the values file as Git has it. Both wait for the rollout, then print the pods by version and the 5-minute error rate. `--env dev|staging` targets another environment.

**Step by step, like CI: `./pipeline`.** The same thing split into stages, for any app with `apps/<app>/`, `helm/<app>/` and `cd/<app>/`:

```sh
./pipeline ci orders-gateway                # test, build, scan (Trivy), load into kind
./pipeline cd orders-gateway dev            # deploy that build to dev ...
./pipeline cd orders-gateway staging        # ... then staging, then prod
./pipeline rollback orders-gateway staging  # back to staging's previous image
```

`ci` refuses a tag it has already built (`--tag T` picks one), and `cd` deploys the last `ci` build unless given `--tag`. The environment is always named: there's no default.

These are Git changes on purpose: `kubectl set image` or `kubectl rollout undo` would be reverted by Argo CD within seconds.

**Tested with traffic flowing.** CI ships and rolls back while three clients hit `:8080` the whole time, and fails on any non-200: 2,641 requests, 0 errors ([run](https://github.com/iantest11111989/orders-gateway-platform/actions/runs/45710719231/job/139544268716)).

**From GitHub instead.** In GitHub mode every merge to `main` builds, scans, signs and pushes an image and commits it to dev; staging and prod move by pull request. Roll back there with a revert PR.

## When it's broken

Work from the symptom inwards:

1. **Is it broken, where, since when?** Grafana → **orders-gateway**, environment picker at the top. The first row shows the SLO, the error budget left and any firing SLO alert. Below: requests by route and status, latency, and pods by version (with a marker at every version change).
2. **What's alerting?** Alertmanager at <http://localhost:9093>. Every alert links to a runbook in [`runbooks/`](runbooks/README.md): what it means, how to confirm it, what to do.
3. **What do the logs say?** Grafana → Explore → Loki. The app's JSON logs parse with no setup:
   ```logql
   {namespace="prod", app="orders-gateway"} | json | status >= 500
   {namespace="prod", app="orders-gateway"} | json | route="/echo" | duration_ms > 250
   ```
4. **Is Kubernetes happy?** `./platform shell`, then `kubectl -n prod get pods,events` and `argocd app list` (or <http://localhost:8081>). `./platform verify` names anything unhealthy.
5. **Was it a release?** If **Pods by version** changed when the errors began, `./platform rollback` first, investigate after.

Fixes go through Git: a `kubectl edit` in an app namespace is undone by Argo CD within seconds.

[`docs/learn/`](docs/learn/README.md) teaches this hands-on, starting with [a tour of the repo](docs/learn/00-repo-tour.md): Prometheus, Grafana, Loki, SLOs and Kubernetes operations, about 15 minutes each on the running stack.

### Troubleshooting the platform itself

Start with `./platform doctor` (Docker, CPU, memory, disk, ports) and `./platform verify`.

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| `doctor`: "Port 80/443 is already in use" | Another web server on the host | Stop it |
| macOS: a port shows another app | A program on the Mac holds the port | `./platform doctor` names it; stop it, then `colima restart` |
| Pods in `ImagePullBackOff` during start-up | A registry rate-limited or flaked | Wait and re-run `./platform up`; Kubernetes keeps retrying |
| `up` fails: "nodes advertise more than their cap" | An old cluster | `./platform down && ./platform up` |
| `budget` reports `OOMKilled` | A container hit its memory limit | `./platform kubectl -n <ns> describe pod <pod>`; limits are in `system/<component>/values.yaml` |
| A pod in `dev`, `staging`, `prod` or `demo` is refused by `disallow-latest-tag` or `verify-image-signatures` | Working as intended | Use a tagged, signed image |
| An app is `OutOfSync` after a manual change | Self-heal puts it back from Git | Change Git, not the cluster |
| `docker compose up -d --wait` waits forever, `ready` unhealthy | The cluster was deleted while an old `ready` kept running | `docker compose down && docker compose up -d --wait` |
| A demo was interrupted | Its copy is left in `demo` | `./platform demo clean` |
| Under Colima, a path in `/tmp` isn't found | Colima only shares your home folder | Keep the checkout under `~` |
| Slow or evicted pods | Docker has less than 6 CPU / 12 GB | `colima start --cpu 6 --memory 12` |

## Under load and failure

The app is a single Node event loop with a 3-second warm-up, a `/readyz` that turns 503 while it drains, and a SIGTERM handler that finishes in-flight requests and exits within 25 s. The chart is built around that:

| Situation | What protects it | Why |
| --- | --- | --- |
| A pod starts | `startupProbe` on `/healthz`, then `readinessProbe` on `/readyz` | Traffic arrives only after the warm-up |
| A pod stops (release, drain, scale-down) | `preStop` sleep 5 s, then SIGTERM; `terminationGracePeriodSeconds: 35` | Traefik drops the pod *before* it stops accepting; 35 s = 5 s + the app's 25 s + margin |
| A release | `maxSurge: 1`, `maxUnavailable: 0` | Never below full capacity |
| A node drain | PodDisruptionBudget (`maxUnavailable: 1`); spread across nodes and zones | One pod at a time; a lost node doesn't take every replica |
| A traffic spike | HPA, 3–6 pods at 70% of a 100m CPU request; **no CPU limit**, 128 Mi memory limit | `/work` burns CPU; a CPU limit would only throttle |
| A busy event loop | a lenient `livenessProbe` (every 10 s, 6 failures) | A busy pod isn't restarted mid-spike |
| A compromised pod | non-root, read-only filesystem, no capabilities, no service-account token, Pod Security `restricted`; NetworkPolicy allows in only Traefik and Prometheus, out only DNS | Least privilege |
| A platform component dies | Argo CD puts back anything deleted; Kyverno fails open; the request path (Traefik → pod) doesn't depend on Prometheus, Loki or Argo CD | The app stays up when the tools around it don't |

**Measured:** k6 at 100 requests/s on `:8080` for 3 minutes: 18,000 requests, **0 failed**, `POST /echo` p99 42 ms. The HPA went from 3 to 6 pods and the cluster peaked at 4.46 of 6 CPU. The demos below each fail unless 99.5% of their requests meet the SLO.

## Observability

| | What | Where |
| --- | --- | --- |
| **App metrics** | `http_requests_total`, `http_request_duration_seconds`, `app_info`, `app_ready`, `app_inflight_requests`; unknown paths are dropped at scrape time so a scanner can't explode the series count | Prometheus `:9090` |
| **Cluster metrics** | kube-state-metrics, node-exporter, kubelet/cAdvisor, and every platform component | Prometheus |
| **Logs** | Alloy ships every pod's output to Loki with four labels (`namespace`, `app`, `env`, `pod`); the app's JSON fields come out with `\| json` | Grafana → Explore → Loki |
| **Dashboards** | 6 dashboards as JSON in [`dashboards/`](dashboards/README.md), loaded automatically; CI checks every query parses. **orders-gateway** for on-call, **platform-overview** for the cluster, plus Argo CD, Kyverno, security and budget | Grafana `:3000` |
| **SLOs** | Availability: 99.5% of `/work` and `/echo` requests aren't 5xx. Latency: 99.5% of `/echo` and `/version` answer within 250 ms (`/work` takes as long as the caller asks, so it's left out) | [`alerts/orders-gateway-slo.yaml`](alerts/orders-gateway-slo.yaml) |
| **Alerts** | Burn-rate alerts: a fast burn pages, a slow burn opens a ticket. Plus delivery and security alerts (Argo CD, certificates, Kyverno, Sealed Secrets, Trivy, memory). Each has a runbook and a unit test; a healthy system fires only Watchdog | Alertmanager `:9093`, [`runbooks/`](runbooks/README.md) |
| **Alert delivery** | Alertmanager → `alert-receiver`, which logs each alert as JSON, routed by severity | Loki: `{namespace="monitoring", app="alert-receiver"}` |
| **Tracing** | **Not done.** The app logs a `trace_id` from a `traceparent` header, so one request can be followed across logs, but there's no tracing backend | |

## Environments, secrets and CI/CD

**Environments.** One chart, three values files: [`cd/orders-gateway/{dev,staging,prod}.yaml`](cd/orders-gateway/), on top of the shared [`cd/orders-gateway/values.yaml`](cd/orders-gateway/values.yaml), override [`helm/orders-gateway/values.yaml`](helm/orders-gateway/values.yaml). dev runs 1 pod, staging 2, prod 3–6 with the HPA, disruption budget, spreading and the `:8080` route. A promotion changes one line: the image tag.

**Secrets.** No plain secrets in the repo: they're SealedSecrets, encrypted for the cluster's Sealed Secrets controller. Its key is a **demo key committed to Git** so every clone can decrypt; a real setup keeps the key out of Git or uses External Secrets. CI fails on any plain `Secret` or private key apart from that demo key. `admin12345` is a published demo login, not a secret.

**GitOps.** By default Argo CD reconciles the cluster from the Git server inside it, with self-heal and prune, and every change (`ship` and `rollback` included) is a commit. In GitHub mode, staging and prod move by pull request: CI opens one per environment for each new image, and the owner merges it.

**The pipeline.** GitHub Actions does CI; Argo CD, inside the cluster, does CD. Every arrow into an environment is a Git commit.

```mermaid
flowchart LR
  pr["Pull request<br/>1 · test, lint<br/>2 · build both arches<br/>rehearse signing"] -->|review, merge| main["main"]
  main --> build["2 · build and push to GHCR<br/>3 · sign (cosign) · scan (Trivy)"]
  build --> devc["4 · commit image to<br/>cd/orders-gateway/dev.yaml"]
  devc --> devs(["Argo CD syncs dev"])
  build --> prs["5 · promotion PRs<br/>for staging and prod"]
  prs -->|"owner merges"| stc["cd/orders-gateway/staging.yaml"]
  stc --> sts(["Argo CD syncs staging"])
  prs -->|"owner merges, after staging"| prc["cd/orders-gateway/prod.yaml"]
  prc --> prs2(["Argo CD syncs prod"])
  localship["Locally: ./platform ship / rollback"] -->|"commit to the cluster's Git server"| prs2
```

| Workflow | When | What it does |
| --- | --- | --- |
| **CI · app** (`ci-app.yml`) | pull requests touching the app | 1 · test, lint → 2 · build (amd64 + arm64), scan, rehearse signing → 3 · smoke-test the image as Kubernetes runs it (non-root, read-only: warm-up, endpoints, metrics, a clean SIGTERM drain) → 4 · a 60 s k6 performance gate held to the SLOs |
| **CD · app** (`cd-app.yml`) | merges to `main` touching the app | 1 · test, lint → 2 · build and push to GHCR → 3 · sign (cosign keyless, SBOM), scan → 4 · deploy dev → 5 · open staging and prod promotion PRs |
| **CI · platform** | pull requests and `main` | shellcheck and actionlint · manifest validation (the chart for every environment, every manifest, checked against Kubernetes and CRD schemas and our policies) · toolbox build · **E2E · Fresh install**: `docker compose up -d --wait` on a fresh runner, restart, re-run, verify, ship and roll back under traffic, budget. It takes about 20 minutes, so on a pull request it runs only with the `run-e2e` label; it always runs on `main`, on promotion PRs and nightly |
| **CI · alerts / policies** | pull requests and `main` | alert unit tests, runbook links and dashboard checks; `kyverno test` |
| **CI · security** | pull requests, `main`, weekly | CodeQL; gitleaks over the whole history |
| **CI · secrets / renovate config** | pull requests and `main` | no plain secrets; Renovate's config is valid |
| **Scheduled** | daily | full start-up, verify, the autoscale and gitops-revert demos on fresh x86-64 and arm64 runners; a re-scan of the running images |

Pull requests run checks only (read-only token, no secrets); pushes to `main` build, sign and promote. Every job declares least-privilege permissions and actions are pinned by commit SHA.

## Resource budget (measured)

`./platform up` caps each kind node at 2 CPU / 4 GiB (6 / 12 in total) and reserves the rest of the host so the scheduler can't overcommit. `./platform budget` measures real use and fails on any out-of-memory kill; `--watch N` samples for N seconds and reports the peak.

Measured on 2026-11-25 on a Mac mini under Colima (6 CPU / 12 GiB, arm64):

| What ran | CPU (peak) | Memory (peak) | OOM kills |
| --- | --- | --- | --- |
| Idle, 2 minutes | 2.24 of 6 | 8,530 MiB (69%) | none |
| k6 at 100 requests/s on `:8080` for 3 minutes (HPA 3 → 6) | **4.46 of 6** | 7,674 MiB (62%) | none |

The largest users at idle: `kube-system` (API server, etcd) 2.3 GiB, `monitoring` 1.3 GiB, `argocd` 0.6 GiB; each app environment uses under 40 MiB.

**Time to healthy:** 9 min 43 s from `docker compose up -d --wait` on a GitHub-hosted runner ([run](https://github.com/iantest11111989/orders-gateway-platform/actions/runs/45710719231/job/139544268716)). Most of it is pulling about 60 images.

## Demos

`./platform demo <name>` narrates each step and says where to watch. Demos run in namespace `demo`, a copy of prod (or of dev for `rolling-update` and `gitops-revert`), so the real environments only change through Git. k6 sends traffic through Traefik (`http://localhost:8084`) the whole time.

| Demo | What happens | Time |
| --- | --- | --- |
| `rolling-update` | v1 → v2 in a 3-pod copy of dev: pods replace one at a time; fails if fewer than 99.5% of requests meet the SLO | ~2 min |
| `chaos` | delete a pod, then drain a worker; the disruption budget lets only one pod go at a time; fails if fewer than 99.5% of requests meet the SLO | ~3 min |
| `gitops-revert` | a bad config commit (30% of requests fail) on a temporary branch that a copy of dev follows; Argo CD syncs it, then `git revert` heals it. Pushes to the cluster's Git server (in GitHub mode, needs `GITHUB_TOKEN`) | ~5 min |
| `autoscale` | k6 sends a fixed 20 requests/s (`AUTOSCALE_RATE`), mostly CPU-heavy `/work`; the HPA scales 3 → 6 pods, then back to 3 about 5 minutes after the load stops | ~8 min |
| `policy` | Kyverno refuses an unsigned image and a `:latest` image, printing which policy refused each and why; a signed image is admitted | <1 min |
| `clean` | delete the demo copy (after an interrupted demo, or `--keep`) | |

Add `--keep` to leave the copy running. Watch in Argo CD or Grafana (environment `demo`).

## Local vs a real cloud

The full plan for running this on AWS (accounts, EKS, IAM, ECR, Argo CD across clusters, Datadog, tests, canaries in prod, DR, cost, on-call) is in [docs/production-on-aws.md](docs/production-on-aws.md). [`docs/terraform-sketch/`](docs/terraform-sketch/README.md) sketches the EKS part in Terraform (never applied). The short version:

| Here (local) | In the cloud | Why it's this way locally |
| --- | --- | --- |
| kind in Docker, 3 nodes, two labelled "zones" | A managed control plane, nodes in 3 real zones, Karpenter adding nodes | One machine |
| dev, staging and prod as namespaces in one cluster, one Argo CD | One account, cluster and Argo CD per environment | The budget |
| Traefik on host ports, 2 replicas | A cloud load balancer in front of 3 Traefik replicas across zones | No load balancer locally |
| Plain HTTP, a port per environment | TLS at the load balancer (ACM), a hostname per environment | No public DNS or certificates |
| Sealed Secrets with a demo key in Git | External Secrets from a secret manager | Must work offline from a clone |
| `admin` / `admin12345` | SSO with roles | A demo login |
| A Git server in the cluster; `ship` loads a local image | GitHub only; prod admits only signed CI images | No registry or token needed |
| Prometheus keeps 24 h | 30+ days, so the real 30-day error budget can be computed | Disk and memory |
| One replica of Argo CD, Kyverno, Prometheus, Loki; Kyverno fails open | HA everywhere; Kyverno fails closed | Memory |
| Alerts to a local receiver | PagerDuty for pages, chat for tickets | No accounts needed |

## What production adds

The local platform keeps promotion manual on purpose. [docs/production-on-aws.md](docs/production-on-aws.md) designs what a real setup adds on top:

- **A patch promoter.** A scheduled job merges a *patch* promotion PR on its own once the previous environment has run that exact image for an hour, its SLO met, no alerts firing and its Application Synced and Healthy. Features still wait for a person. A `promotion/PAUSED` file stops it, for freezes and spent error budgets.
- **Patch or feature, decided by CI.** When CI opens a promotion PR it reads the commits in the range: a `Promotion-Kind: patch|feature` trailer, or conventional commits (`fix:` vs `feat:`). Only patches can merge automatically.
- **Where each environment stands.** Argo CD reports every sync to GitHub as a Deployment, so the repo's Environments panel shows what dev, staging and prod run and since when.

## Limitations

- **No TLS locally.** Everything is plain HTTP on `127.0.0.1`; production terminates TLS at the load balancer.
- **Releases are rolling updates, not canaries.** A bad version reaches every pod before anyone notices; the SLO alerts and `./platform rollback` are the safety net. [docs/production-on-aws.md](docs/production-on-aws.md) covers canaries for a real setup.
- **Kyverno fails open.** If it's down, pods are admitted unchecked, so a policy outage can't block a rollback.
- **Prometheus keeps 24 hours,** so the error-budget panels cover a day, not 30 days.
- **The Sealed Secrets key is public,** by design. Anything sealed with it is effectively public.
- **First start pulls about 60 images.** A slow registry can stretch start-up; re-running is safe.
- **No tracing backend.** Requests correlate across logs by `trace_id` only.
- **The app's latency fault only slows `/work`,** which the latency SLO leaves out, so injected latency doesn't trip the latency alert. Saturating the event loop with `/work` does (see [docs/learn/04-slos.md](docs/learn/04-slos.md)).

**Next steps:** tracing with Tempo and OpenTelemetry; canary releases; applying the Terraform to a sandbox account.

## Repository layout

```
apps/orders-gateway/    the service (server.js), Dockerfile, tests, k6 scripts
helm/orders-gateway/    its Helm chart
cd/orders-gateway/      what each environment runs: values.yaml (shared), dev.yaml, staging.yaml, prod.yaml
bootstrap/              root.yaml (what ./platform up applies) and the app-of-apps chart: one Argo CD Application per component
system/<component>/     shared cluster components: Helm values and/or plain manifests (traefik, argocd, kube-prometheus-stack, ...)
policies/               Kyverno policies and tests
dashboards/             Grafana dashboards (JSON)
alerts/                 Prometheus alert rules and tests
runbooks/               one per alert
platform                the CLI: the cluster (up, down, verify, demos, ...)
pipeline                ci, cd and rollback for an app, locally
scripts/                what ./platform runs inside the toolbox
cluster/                kind cluster config
toolbox/                toolbox image
docs/learn/             hands-on exercises
docs/production-on-aws.md  the plan for running it on AWS
docs/terraform-sketch/  the EKS part in Terraform (not applied)
.github/workflows/      CI/CD
```

## License

[MIT](LICENSE)
