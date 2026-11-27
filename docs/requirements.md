# Requirements, and where each is met

The platform is built to a fixed set of requirements: a local "cluster in a box" around a small service, `orders-gateway`, showing how to run, ship, observe and operate it on Kubernetes. This page goes through them one by one and says where each is met. Where the repo chooses differently on purpose, it says so.

Status: **done** means built and checked by a demo, `./platform verify` or CI. **Partly** and **skipped** say what is missing and why.

## Ground rules

| Requirement | Status | Where it's answered |
| --- | --- | --- |
| `docker compose up -d --wait` is all it takes | done | [README: Start it](../README.md#start-it) |
| Fits 6 CPU / 12 GB on an 8 vCPU / 16 GB x86-64 Linux VM | done | `./platform budget` checks it. Each kind node is capped (2 CPU / 4 GiB) in [`stack/cluster/kind.yaml`](../stack/cluster/kind.yaml) |
| Healthy in under 15 minutes | done | About 10 minutes on a first start, mostly pulling images. The nightly E2E starts from scratch on x86-64 and arm64 |
| The interesting part runs inside Kubernetes; justify the choice of kind, k3d, k3s or minikube | done | kind. See [Key decisions](#key-decisions) below |
| Everything in the cluster installed declaratively with Helm or Kustomize, automatically | done | Argo CD installs every component from a Helm chart, itself included: [`stack/delivery/bootstrap/`](../stack/delivery/bootstrap/README.md) |
| Open-source tools only, with pinned versions | done | Tools: [`stack/toolbox/versions.env`](../stack/toolbox/versions.env). Charts: `stack/delivery/bootstrap/apps/templates/`. Images and actions are pinned by digest. Renovate keeps them current |
| Don't change the app except by configuration | done | `server.js` is byte-for-byte the original. It moved from `app/` to `apps/orders-gateway/app/` so a second app can sit beside it. The Dockerfile is new |
| Mark what you skipped and why | done | [Skipped, and why](#skipped-and-why) below |

## The fixed contract

`./platform demo contract` checks every row live, read-only, in under a minute.

| Row | Status | How |
| --- | --- | --- |
| A Compose service `ready`, healthy only when everything is installed and the app serves | done | Its healthcheck ([`scripts/ready-check.sh`](../scripts/ready-check.sh)) passes only when every Argo CD Application is Synced and Healthy and prod answers on :8080 |
| `./out/kubeconfig.yaml`, usable from the host | done | Written by the bootstrap |
| dev, staging and prod each run a Deployment named `app`, labelled `app.kubernetes.io/name=app` | **changed on purpose** | The Deployment and label are `orders-gateway`, so two apps can share a namespace. Why: [naming.md](naming.md) |
| prod through an Ingress at `http://localhost:8080`; `/admin/*` unreachable from outside | done | Traefik serves the Ingress. `/admin/*` gets a 403 at the edge and still works inside the cluster |
| UI logins `admin` / `admin12345` | done | Grafana and Argo CD |
| Grafana :3000, Prometheus :9090, Alertmanager :9093 | done | [README: URLs and logins](../README.md#urls-and-logins) |
| Restart policies; data that matters survives `docker compose stop` / `start` | done | Every Compose service has `restart: unless-stopped`. The cluster runs in kind's own containers, so registry versions, Git history and Prometheus data survive. The E2E checks this with [`scripts/persistence-check.sh`](../scripts/persistence-check.sh) |

## 1. Kubernetes workloads

| Requirement | Status | Where |
| --- | --- | --- |
| A Helm chart or Kustomize, justified | done | A Helm chart: [`apps/orders-gateway/chart/`](../apps/orders-gateway/chart/README.md). Why Helm: [Key decisions](#key-decisions). Each setting tied to what `server.js` does: [the chart README](../apps/orders-gateway/chart/README.md#how-the-app-behaves-and-what-the-chart-does-about-it) |
| Resources | done | 100m CPU request, no CPU limit (it would throttle the single event loop), 48Mi request and 128Mi limit for memory |
| Probes | done | A startup probe covers the app's 3 s warm-up, then readiness on `/readyz`. Liveness is lenient because `/work` blocks the event loop |
| Rollout and shutdown | done | `maxSurge: 1`, `maxUnavailable: 0`. A `preStop` sleep of 5 s lets Traefik stop sending traffic first, then the app has 25 s to drain on SIGTERM, within a 35 s grace period |
| Disruption budgets | done | At most one pod down during a drain |
| Autoscaling | done | HPA at 70% CPU: 3 to 6 pods in prod, 2 to 4 in staging, so a release meets autoscaling before prod |
| Security context | done | Non-root, read-only root filesystem, no capabilities, RuntimeDefault seccomp, no service account token. The app namespaces enforce Pod Security `restricted`, and Kyverno adds a read-only root filesystem rule |
| Network policy | done | Traffic in only from Traefik and Prometheus, out only to DNS |
| Configuration and secrets | done | Settings are chart values that become a ConfigMap. Secrets are SealedSecrets (see section 2) |

## 2. Environments, release and rollback

| Requirement | Status | Where |
| --- | --- | --- |
| Environments differ through values files, not copies | done | One shared `apps/orders-gateway/cd/values.yaml`, plus a short `dev.yaml`, `staging.yaml` and `prod.yaml` |
| No manual steps; re-running is safe | done | `docker compose up -d --wait` again is safe, and so is `./platform up` |
| One documented way to ship a new version, followed while traffic flows | done | [README: Ship a version](../README.md#ship-a-version). `./pipeline ci` tests, builds, scans and publishes. `./pipeline cd` deploys it through Git. The `release` demo and the E2E check that no request fails during a release |
| One documented way to roll back | done | `./pipeline rollback orders-gateway <env>`. The E2E rolls prod back under traffic |
| No plaintext secrets; something sensible for local, and why | done | The Grafana login is a SealedSecret, encrypted in Git, so it can be committed safely. Argo CD's is a bcrypt hash in its values, because Argo CD installs before the Sealed Secrets controller exists. The one exception is the Sealed Secrets private key itself, committed on purpose so a fresh clone can decrypt them. It is labelled demo-only, CI blocks any other plain Secret, and in production it would be replaced by a secret manager ([production.md](production.md)) |

## 3. GitOps and CI/CD

| Requirement | Status | Where |
| --- | --- | --- |
| Argo CD or Flux, from a Git server the stack hosts | done | Argo CD reads from a small Git server inside the cluster ([`stack/delivery/git-server/`](../stack/delivery/git-server/)) |
| Self-healing and pruning | done | Both on. Scale a Deployment by hand and Argo CD puts it back within seconds ([learn/05](learn/05-k8s-operations.md)) |
| Promotion by Git change | done | `./pipeline cd` commits the version to the environment's file. The `gitops-revert` demo shows a bad commit healed by `git revert` |
| Workflows valid on real GitHub: lint and test, build, scan | done | [`.github/workflows/`](../.github/workflows/), listed in [README: Tests and CI](../README.md#tests-and-ci) |
| Push, and update of the desired state | **partly** | Done locally by `./pipeline`, not by GitHub Actions. That way anyone who clones the repo can run the whole flow against their own cluster without a CI account or registry. Pull requests run the build and a signing rehearsal but push nothing. How it would move to CI: [production.md: Shipping and rolling back](production.md#shipping-and-rolling-back) |
| Running the pipeline locally, with evidence | done | `./pipeline` itself runs locally and prints every step. The `hello-world` demo and the E2E run it end to end |
| Bonus: least-privilege tokens, caching, PR versus main triggers | done | Every workflow starts at `contents: read`. The E2E caches images. Pull requests check, `main` runs the E2E |
| Bonus: SBOM and signing | partly | Builds produce an SBOM and are signed keylessly with cosign in a rehearsal. Kyverno's `verify-image-signatures` policy admits only CI-signed images from the repo's registry. Local `./pipeline` builds are unsigned and admitted because they come from the in-cluster registry |
| Bonus: approvals for prod | done | Staging and prod don't sync by themselves: someone checks the diff and clicks Sync in Argo CD (or passes `--sync`). Promotion is refused unless the previous environment is healthy and has no alert firing |

## 4. Observability

| Requirement | Status | Where |
| --- | --- | --- |
| Metrics: app, cluster, nodes | done | Prometheus scrapes the app, kube-state-metrics and node-exporter |
| Logs searchable, JSON usable without extra work | done | Alloy ships every pod's output to Loki. `| json` gives the app's fields ([learn/03](learn/03-loki.md)) |
| A dashboard that answers "is it broken, where, since when" in 30 seconds, plus a cluster overview | done | **orders-gateway** (SLO and alerts first, then traffic, latency, pods by version, logs) and **platform-overview**, as code in [`stack/observability/dashboards/`](../stack/observability/dashboards/README.md) |
| SLOs for availability and latency, multi-window burn-rate alerts | done | 99.5% of `/work` and `/echo` succeed; 99.5% of `/echo` and `/version` answer within 250 ms. Fast and slow burn alerts: [`stack/observability/alerts/`](../stack/observability/alerts/README.md). Explained in [learn/04](learn/04-slos.md) |
| Symptom-based, actionable alerts with runbooks | done | Each alert links to a runbook in [`stack/observability/runbooks/`](../stack/observability/runbooks/README.md). CI checks the links |
| A quiet, healthy system has no alerts | done | Only Watchdog fires, on purpose, to prove alerts get through |
| Alerts routed through Alertmanager to a local receiver, delivery observable | done | A small receiver logs each alert into Loki. The `alert` demo follows one from firing to resolved |
| [stretch] Distributed tracing, log-to-metric and trace correlation | **partly** | No tracing backend. The app logs a `trace_id` from the `traceparent` header, so one request can be followed through the logs, and LogQL turns logs into metrics ([learn/03](learn/03-loki.md)) |

## 5. Operating it under stress

| Requirement | Status | Where |
| --- | --- | --- |
| Traffic that rises sharply | done | `autoscale` demo, on prod: the HPA goes from 3 to 6 pods and back. A load test on :8080 reached about 1300 requests/s with no errors |
| Rolling releases | done | `release` demo: a new version to prod under load, one pod at a time, no failed requests |
| Pods killed | done | `chaos` demo: a pod deleted and a worker drained. The disruption budget keeps it serving |
| Platform components killed | done | `platform-chaos` demo: Traefik, CoreDNS, Argo CD, Prometheus and Kyverno pods deleted under load, one at a time |
| Document what you did and why | done | [README: Demos](../README.md#demos), [the chart README](../apps/orders-gateway/chart/README.md) |

Every demo runs on the real prod at :8080 (or another environment you name), and fails if fewer than 99.5% of requests meet the SLO.

## 6. Documentation

| Requirement | Status | Where |
| --- | --- | --- |
| Architecture diagram and key decisions with trade-offs | done | [README: How it works](../README.md#how-it-works), [Key decisions](#key-decisions) below |
| How do I ship? Roll back? Debug? | done | [README: Ship a version](../README.md#ship-a-version), [When something breaks](../README.md#when-something-breaks) |
| What differs from a real cloud deployment, and what you'd change | done | [README: Local versus production](../README.md#local-versus-production), [production.md](production.md) |
| [stretch] Sketch the Terraform | done | [terraform-sketch/](terraform-sketch/README.md), EKS, never applied |
| Honest limitations and what you'd do next | done | [Skipped, and why](#skipped-and-why) and [What next](#what-next) below |

## Key decisions

- **kind**, not k3d, k3s or minikube. It runs upstream Kubernetes in Docker containers, needs nothing on the host but Docker, and gives real multi-node clusters: one control plane and two workers in different zones, so the disruption budget, zone spreading and node drains can be shown. The trade-off: it needs the Docker socket, which gives the bootstrap container full control of Docker.
- **Helm**, not Kustomize. Every third-party component ships as a Helm chart, so one tool installs everything. The app's chart has real logic (HPA, disruption budget and network policy switched per environment, image digests), which is easier in Helm values than in overlays. The trade-off: templates are harder to read than plain manifests.
- **Argo CD** installs the platform as well as the apps, from a Git server inside the cluster. Everything is declarative and self-healing, and the bootstrap only has to install Argo CD itself.
- **Traefik** is the only way in, so `/admin/*` can be refused in one place, at the edge.
- **Sealed Secrets** because it works offline with no external service, and encrypted secrets can live in Git.
- **CI/CD runs locally** (`./pipeline`) so the whole ship-and-rollback flow can be practised against your own cluster. GitHub Actions only checks pull requests.
- **One cluster with three namespaces**, to fit 6 CPU / 12 GB. In production each environment gets its own cluster.

## Skipped, and why

- **Distributed tracing.** It would need a tracing backend and SDK changes to the app, and the app is left unchanged on purpose. `trace_id` in the logs covers following one request.
- **Publishing releases from GitHub Actions.** Done locally instead, as explained above. [production.md](production.md#shipping-and-rolling-back) describes the CI version.
- **Canary releases.** Releases are rolling updates, so a bad version reaches every pod before the SLO alert fires. Rollback is one command.
- **High availability for the platform.** One replica each of Argo CD, Kyverno, Prometheus and Loki, to fit the budget. Kyverno fails open so its outage can't block a rollback.
- **30-day error budgets.** Prometheus keeps 24 hours, so budget panels cover a day.
- **TLS and hostnames.** Plain HTTP on local ports, as the contract asks.

## What next

1. Publish signed releases from CI on merge to main, and make promotion a pull request ([production.md](production.md#shipping-and-rolling-back)).
2. Canary releases with Argo Rollouts, gated on the new version's SLOs.
3. Add OpenTelemetry tracing when the app can change, with Tempo or a vendor, linked from log lines.
4. Move monitoring to Datadog for a real 30-day error budget and paging ([production.md](production.md)).
5. Run Kyverno and Argo CD with 3 replicas, and make Kyverno fail closed for the app namespaces.
