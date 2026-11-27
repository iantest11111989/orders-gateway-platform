# Running this in production

What would change between this local setup and a real cloud deployment, and why. None of it is built. [`infra-sketch/`](infra-sketch/README.md) sketches the cloud infrastructure (VPC, subnets, EKS) in Terraform.

## What changes

| Here | In production | Why |
| --- | --- | --- |
| One kind cluster; dev, staging and prod are namespaces | A managed cluster (EKS or similar) per environment, each in its own cloud account, nodes across 3 zones | A mistake in dev can't reach prod, and losing a zone doesn't take the app down |
| A Git server inside the stack, one Argo CD | GitHub, and an Argo CD in each cluster that deploys only its own environment | No cluster holds credentials for another |
| A registry inside the stack | ECR (or similar), with immutable tags | |
| `./pipeline` on your machine | GitHub Actions on merge to main (see below) | Releases should be built by a known, reviewed identity, not a laptop |
| Traefik on `localhost` ports, plain HTTP | An ALB from the AWS Load Balancer Controller with TLS and a hostname per environment | |
| Sealed Secrets with a public demo key | External Secrets reading a secret manager (AWS Secrets Manager) | The demo key is public by design |
| Prometheus (24 h), Loki, Grafana, alerts to a local receiver | Datadog or a similar service; pages to PagerDuty | 30 days of data for the real error budget, and no monitoring stack to run |
| `admin` / `admin12345` | SSO for people; read-only in prod, changes go through Git | |
| One replica of Argo CD, Kyverno and the monitoring stack; Kyverno fails open | 3 replicas each; Kyverno fails closed for app namespaces | Fail-open here keeps a Kyverno outage from blocking a rollback on one machine |
| `./pipeline` images are unsigned; the in-stack registry is trusted | Only images signed by CI on main are admitted | The `verify-image-signatures` policy already checks CI-signed images; it would cover every app image |

What stays the same: the Helm chart, the env files in `apps/<app>/cd/`, Argo CD's app-of-apps, the Kyverno policies, the SLOs and their runbooks, and the app's metrics and JSON logs.

## Shipping and rolling back

Here, CI/CD runs locally so anyone who clones the repo can practise every step without their own CI or registry. In production the same flow moves to CI:

1. A pull request sets the new version. Merging it to main runs CI: test, build, scan, sign, then push the image and chart to the registry under that version and tag the commit (`orders-gateway-v1.2.0`).
2. CI commits the version and image digest to `apps/<app>/cd/dev.yaml`. Dev's Argo CD deploys it.
3. Staging and prod move by **promotion PR**: a PR that changes only that environment's file. Its checks are the gates `./pipeline cd` runs today: the previous environment runs this version, is Synced and Healthy, and has no alert firing. Prod also needs an approval. Merging is the deploy.
4. **Rollback** is a revert PR of the promotion commit.

The image is built once and pinned by digest, so prod runs exactly what dev ran. CI never talks to a cluster; Argo CD pulls from Git.

## Keeping it patched

Most security fixes arrive as new versions of something the platform already runs, so updates have to flow in by themselves, without waiting for someone to notice.

**Here**, [Renovate](../renovate.json5) runs every day against the repo. It knows every pinned version: the Helm charts in `stack/delivery/bootstrap/apps/`, the images (pinned by digest), the tools in the toolbox (`stack/docker/versions.env`), the GitHub Actions and the kind node image. For each one with a newer version it opens a pull request.

- **Patch and digest updates merge themselves** once the pull request's CI checks pass: lint, manifest and policy validation, and the scans. The full E2E then runs on main after the merge. That's where most security fixes land.
- **Minor and major updates wait for a person**, labelled `needs-owner-approval`.
- **Some never auto-merge:** Argo CD (it deploys itself, so a bad update has no automatic way back), and kind with its node image (they must match).
- **Some move together**, so their versions always match: a chart and its CLI (Kyverno, Sealed Secrets, Argo CD), and kube-prometheus-stack with its CRDs.
- The app's own image is left out: CI and promotion move it.

The Trivy Operator scans what is actually running and reports vulnerable images, which catches what Renovate can't, such as an image with no fix released yet.

**In production**, the same Renovate setup keeps running against the GitHub repo, and a merged update goes out the same way as any change: dev first, then staging and prod by promotion. Three layers are added on top:

- **Nodes.** EKS managed node groups roll onto each new patched AMI (or Bottlerocket updates itself), one node at a time. The disruption budgets keep the app serving, as the `chaos` demo's drain shows.
- **Kubernetes.** The EKS version is upgraded on a schedule, dev first, before AWS ends support for the old one.
- **App images.** Rebuilt on a schedule as well as on change, so a fixed base image reaches the app even when its code doesn't change. Prod admits only images signed by CI.

## Worth exploring

- **Canary releases.** Here a release is a rolling update, so a bad version reaches every pod. Argo Rollouts could send 5% of traffic to the new version, check the SLOs for that version only, and roll back automatically if they fail. Not built here.
- **Running your own observability** instead of a vendor: today's Prometheus, Loki and Grafana, with long-term storage (Thanos or Mimir) and HA. Cheaper at scale, but it's a system to operate.
- **Other ways in**, such as the AWS Load Balancer Controller without a proxy: the ALB sends traffic straight to the pods, and an ALB rule or AWS WAF blocks `/admin/*`. One component fewer to run.
- **Proxies.** A reverse proxy such as NGINX or Envoy in front of the app.
- **Costs.** Evaluate before choosing: a cluster per environment, NAT gateways and the observability vendor's pricing drive most of the bill.
