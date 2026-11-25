# orders-gateway-platform

A local, reproducible **"cluster in a box"** that shows how a platform team would **run, ship, observe and operate** a small stateless HTTP service, `orders-gateway`, on Kubernetes.

The service is a small Go stand-in. The platform around it is the real point: GitOps with Argo CD, canary releases with Argo Rollouts, HTTPS through Envoy Gateway, metrics and logs with Prometheus, Grafana and Loki, and a security baseline that keeps itself patched.

> **Status: work in progress.** This repo is being built in small, reviewed pull requests. Sections marked _(coming)_ are placeholders.

## Prerequisites

**Docker only.** Every other tool (kind, kubectl, helm, kubeseal, cosign, k6, the argocd CLI, jq, yq) is pinned and shipped in a toolbox container image that the `./platform` script runs for you.

| | Reference machine | Development machine |
| --- | --- | --- |
| Hardware | 8 vCPU / 16 GB, x86-64 Linux | Apple silicon Mac (arm64), 16 GB |
| Docker | Docker Engine | Colima: `colima start --cpu 6 --memory 12` |

The whole stack is designed to fit in **6 CPUs and 12 GB RAM**.

## Quick start

```sh
git clone https://github.com/iantest11111989/orders-gateway-platform.git
cd orders-gateway-platform
./platform doctor   # check Docker, CPU, memory, disk and ports
./platform up       # create the cluster (safe to re-run)
./platform verify   # check apps, scrape targets, logs, HTTPS and policies
./platform urls     # every URL and login
./platform budget   # measured CPU and memory against the 6 CPU / 12 GiB budget
./platform demo canary   # and the other demos below
./platform shell    # a shell with kubectl, helm, argocd, k6, ... pointed at the cluster
./platform down     # delete it all (safe to re-run)
```

`up` creates the kind cluster (1 control plane + 2 workers), installs Argo CD and hands it the root Application, then waits until every Application is Synced and Healthy. From then on Argo CD manages everything, including itself, from Git, in sync waves (CRDs, then controllers, then observability, policies and the gateway, then the apps). From a clean machine that takes about 6–7 minutes, most of it pulling images (358–427 s in the nightly end-to-end run on fresh GitHub runners). `./platform verify` then checks the running stack: every Application Synced and Healthy, every Prometheus target up, logs in Loki from every namespace, HTTPS on every hostname, and Kyverno flagging a bad manifest. `./platform budget` measures what the cluster uses against the 6 CPU / 12 GiB budget (`--watch 120` reports the peak while something runs).

To run from your fork or a branch: `REPO_URL=https://github.com/<you>/orders-gateway-platform.git REVISION=my-branch ./platform up`.

`./platform` runs everything inside a **toolbox** container with every tool pinned and checksum-verified (`toolbox/versions.env`). The first run pulls or builds it. Set `TOOLBOX_IMAGE` to use a different image.

> **Security note:** the toolbox mounts the Docker socket so kind can create its node containers. That gives it root-equivalent access to your Docker host, which is normal for kind but worth knowing. Run it on a machine you control. With Colima, keep the checkout inside your home folder.

## What's inside

| Area | Choice |
| --- | --- |
| Local cluster | kind: 1 control plane + 2 workers |
| Packaging | Helm chart |
| GitOps | Argo CD, app-of-apps, Argo CD manages itself |
| Progressive delivery | Argo Rollouts with `workloadRef` |
| Traffic | Gateway API with Envoy Gateway |
| TLS | cert-manager with a local demo CA |
| Metrics | Prometheus, Alertmanager, Grafana (kube-prometheus-stack) |
| Logs | Loki (single binary) + Alloy |
| Policy | Kyverno |
| Secrets | Sealed Secrets (demo key, **demo only**) |
| Scanning and signing | Trivy (CI and Trivy Operator), cosign keyless |
| CI and updates | GitHub Actions, Renovate |
| Environments | dev, staging, prod namespaces |

## URLs

All hostnames use `*.localtest.me`, which resolves to `127.0.0.1`.

- `https://orders.dev.localtest.me`, `https://orders.staging.localtest.me`, `https://orders.localtest.me`
- `https://argocd.localtest.me`, `https://grafana.localtest.me`, `https://prometheus.localtest.me`, `https://alertmanager.localtest.me`, `https://rollouts.localtest.me`

`./platform urls` prints them with the logins (Argo CD's admin password, and Grafana's, which comes from a SealedSecret) and how to trust the demo CA.

## Demos

`./platform demo <name>` narrates each step in the terminal and says where to watch it. The demos run in `orders-demo`, a copy of the live `orders-prod` (canary, chaos and autoscale) or `orders-dev` (rolling update) Application, so the real environments only ever change through Git ([decision 0020](docs/decisions/0020-demos-in-a-copy-of-prod.md)). k6 sends ~10 requests/s through the gateway while they run (`autoscale` sends more).

| Demo | What happens | Time |
| --- | --- | --- |
| `rolling-update` | v1 → v2 in a 3-replica copy of dev: pods replace one at a time (`maxSurge: 1`, `maxUnavailable: 0`), and the demo fails if fewer than 99.5% of k6's requests meet the SLO | ~2 min |
| `chaos` | in a copy of prod: delete a pod, then drain a worker for the demo's pods (cordon + evictions, like `kubectl drain`). The PodDisruptionBudget refuses a second eviction until a replacement is ready; fails if fewer than 99.5% of k6's requests meet the SLO | ~3 min |
| `gitops-revert` | a bad config commit (`FAULT_ERROR_RATE` 0.3) on a temporary `demo/gitops-revert-*` branch that a copy of dev follows: Argo CD syncs it and ~30% of orders fail; `git revert` heals it. Needs `GITHUB_TOKEN` with push access to the repo the cluster syncs from (your fork, `REPO_URL`); the branch is deleted afterwards | ~5 min |
| `canary` | v1 → v2: Rollouts moves traffic 10% → 25% → 50% → 100% and the SLO analysis passes at each step | ~8 min |
| `canary-fail` | v2 → v2-bad: the first analysis fails the SLO, Rollouts aborts and sends all traffic back to v2 | ~3 min |
| `autoscale` | in a copy of prod whose pods request 10m CPU (prod: 50m, so a laptop-sized load is enough). The HPA is prod's own (3–6 pods, 70% CPU target); only the request it measures against changes: k6 sends a fixed rate (`AUTOSCALE_RATE`, default 180 requests/s), CPU goes past the HPA's 70% target and it scales the Rollout from 3 to 6 pods; when k6 stops it scales back to 3 after the HPA's 5-minute scale-down window. Fails if it doesn't scale up, or isn't back at 3 within 10 minutes | ~8 min |
| `policy` | Kyverno refuses two pods created for real in `orders-demo`: an orders-gateway image without main's signature (the unsigned image staging and prod ran until 2026-11-25) and a `:latest` image. Each prints the policy that refused it and why. A signed image is admitted (dry run). Nothing is left running ([decision 0022](docs/decisions/0022-enforce-in-orders.md)) | <1 min |
| `clean` | deletes the demo copy (after an interrupted demo, or `--keep`) | |

Add `--keep` to leave `orders-demo` running afterwards. Watch in the Rollouts dashboard (`https://rollouts.localtest.me/rollouts/orders-demo`), Argo CD, or Grafana. Run `./platform budget --watch 600` in a second terminal to see the peak.

## Repository layout

```
app/                    Go source, Dockerfile, tests, k6 scripts
charts/orders-gateway/  Helm chart
environments/           dev, staging and prod values
gitops/                 Argo CD Applications per component
policies/               Kyverno policies and tests
dashboards/             Grafana dashboards (JSON)
alerts/                 PrometheusRules
runbooks/               one per alert
platform                the CLI script
scripts/                what ./platform runs inside the toolbox
cluster/                kind cluster config
toolbox/                toolbox image
docs/decisions/         architecture decision records
docs/learn/             hands-on exercises
.github/workflows/      CI
```

## Production differences

- **Metrics retention.** Prometheus here keeps 24 hours of data, enough for the burn-rate alerts (at most 6 h), so the error-budget panel covers only that window. Production would keep 30+ days, for example in long-term storage, so the true 30-day error budget can be computed.
- **TLS and DNS.** Certificates here come from a demo CA created inside each cluster, and `*.localtest.me` resolves to 127.0.0.1. Production would use a public CA (Let's Encrypt via ACME DNS-01) or the company PKI, with real DNS records.
- **Ingress.** Here Envoy listens on NodePorts mapped to 127.0.0.1:80/443, with one proxy replica. Production would use a cloud load balancer, two or more proxy replicas spread across zones, and SSO in front of Prometheus and Alertmanager, which have no login of their own.

## Further sections _(coming)_

Architecture diagram, resource budget (measured), why these choices, troubleshooting.

## License

[MIT](LICENSE)
