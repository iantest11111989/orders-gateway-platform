# 0009: orders-gateway Helm chart and the dev/staging/prod environments

**Status:** Accepted, 2026-11-23

## Context

The brief (section 7) asks for a production-quality Helm chart, and three environments in one cluster (dev, staging, prod), each a namespace with its own values file and Argo CD Application, promoted by Git changes. Images are published from `main` to GHCR (PR #9). The prod canary (Argo Rollouts with `workloadRef`), Sealed Secrets and CI promotion each come in their own PR.

## Choices

- **One chart, three values files.** `charts/orders-gateway/` holds every default; `environments/<env>/values.yaml` holds only what differs (replicas, HPA, PDB, spread, hostname, log level, image). Argo CD renders the chart from this repo with `valueFiles: ../../environments/<env>/values.yaml`, so promotion is a one-line change to `image.tag`.
- **Image by tag, optionally pinned by digest.** `image.tag` is required (`required` fails the render without it). `image.digest` makes the pod run `repository@sha256:...`, because the demo tags are rebuilt from `main` and so are mutable. Image verification (security PR) can pin digests too.
- **Namespaces `orders-dev`, `orders-staging`, `orders-prod`**, created by Argo CD with Pod Security `restricted` enforced. That matches the namespaces the SLO tests already use (decision 0006); the SLO rules aggregate by namespace, so every environment gets its own SLIs and alerts with no extra rules.
- **Pods carry `env: <env>`**, which Alloy turns into the `env` log label (decision 0007).
- **NetworkPolicy in the chart**: ingress only from `envoy-gateway-system` (traffic) and `monitoring` (scrapes) on the app port, egress only DNS to kube-dns. kindnet enforces it. Namespace-wide default-deny policies belong to the security PR.
- **Probes**: startup (`/healthz`, up to 30 s), liveness (`/healthz`), readiness (`/readyz`, every 2 s, fails on the first miss so a draining pod leaves the Service fast). `terminationGracePeriodSeconds: 30` covers the app's 5 s drain + 20 s shutdown limit. Rolling updates use `maxUnavailable: 0`.
- **metrics-server** (chart 3.14.0, wave 10, `kube-system`), so the prod HPA can read CPU. It runs with `--kubelet-insecure-tls` because kind's kubelet certificates don't name the node IPs (demo only).
- **Wave 40** for the three app Applications, after the gateway (15) and monitoring (20, 25).

## Tests

- `helm lint` and `helm template` for each environment; a server-side dry run of each rendered environment against the live cluster.
- Live, with the v2 image loaded into kind, the prod values were installed into a scratch namespace (since removed):
  - 3 pods Ready under PSA restricted, spread across both zones.
  - `POST https://orders.localtest.me/orders` returned 201 with v2's `estimated_delivery`.
  - A pod in another namespace was blocked by the NetworkPolicy.
  - 3 scrape targets up, and the SLO recording rules from `alerts/` computed for the new namespace.
  - After metrics-server: `kubectl top` works, and the HPA reads `cpu: 2%/70%` with 3 replicas.

## Resource impact

orders-gateway: dev 1 pod, staging 2, prod 3 (up to 6). Requests are 25m/32Mi (50m in prod) with a 64Mi limit; each pod uses about 8 MiB. In total that's 0.2 CPU and 0.2 Gi requested, 0.4 Gi in limits (0.6 Gi at 6 prod pods). metrics-server adds 20m/48Mi with a 128Mi limit.

## Consequences

- The environments need the GHCR package to be **public**, because kind pulls anonymously.
- Until the promotion PR, image tags in `environments/` are bumped by hand (by PR).
