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
./platform shell    # a shell with kubectl, helm, argocd, k6, ... pointed at the cluster
./platform down     # delete it all (safe to re-run)
```

Today `up` creates the kind cluster (1 control plane + 2 workers), installs Argo CD and hands it the root Application, then waits until every Application is Synced and Healthy. That takes about 80 seconds from a clean machine with images cached. From then on Argo CD manages everything, including itself, from Git. `./platform urls` prints the Argo CD login. The rest of the platform arrives in the next pull requests, along with `verify`, `budget` and `demo`.

To run from your fork or a branch: `REPO_URL=https://github.com/<you>/orders-gateway-platform.git REVISION=my-branch ./platform up`.

`./platform` runs everything inside a **toolbox** container with every tool pinned and checksum-verified (`toolbox/versions.env`). The first run pulls or builds it. Set `TOOLBOX_IMAGE` to use a different image.

> **Security note:** the toolbox mounts the Docker socket so kind can create its node containers. That gives it root-equivalent access to your Docker host, which is normal for kind but worth knowing. Run it on a machine you control. With Colima, keep the checkout inside your home folder.

## What's inside _(coming)_

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

## URLs _(coming)_

All hostnames use `*.localtest.me`, which resolves to `127.0.0.1`.

- `https://orders.dev.localtest.me`, `https://orders.staging.localtest.me`, `https://orders.localtest.me`
- `https://argocd.localtest.me`, `https://grafana.localtest.me`, `https://prometheus.localtest.me`, `https://alertmanager.localtest.me`, `https://rollouts.localtest.me`

## Demos _(coming)_

`./platform demo <name>`: `rolling-update`, `canary`, `canary-fail`, `autoscale`, `chaos`, `policy`, `gitops-revert`.

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

## Further sections _(coming)_

Architecture diagram, resource budget (measured), why these choices, troubleshooting.

## License

[MIT](LICENSE)
