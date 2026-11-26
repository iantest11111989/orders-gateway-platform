# Running orders-gateway-platform in production on AWS

Status: a plan for discussion. Nothing here has been built or applied. It extends [`docs/terraform-sketch/`](terraform-sketch/README.md) and the README's [Local vs a real cloud](../README.md#local-vs-a-real-cloud) table.

**How to read it.** §1 is the target in one paragraph and a diagram. §2 maps every local component to its production replacement. §3 goes area by area (accounts, EKS, identity, images, GitOps, ingress, secrets, Datadog, tests, canaries, DR, cost, security, operations). §4 is the Terraform layout, §5 the migration order, §6 the decisions the owner has to make. Where there are two reasonable options, both are given with a recommendation.

Conventions: "**Recommend**" is the opinionated pick. "*(unsure)*" marks things not yet verified (prices, newer AWS/Datadog features). Prices are approximate eu-west-1 list prices from memory and must be checked before anyone budgets on them.

---

## 1. Summary and target shape

Production drops Docker Compose, kind and the in-stack Git server. Terraform builds an **AWS Organization with one account per environment** (dev, staging, prod), plus shared-services (ECR, CI roles, root DNS) and the usual security and log-archive accounts. Each environment account has **its own VPC across 3 AZs** (public subnets for the load balancer and NAT, private subnets for nodes) and **its own EKS cluster**, with nodes on Graviton managed by **Karpenter**. **Each cluster runs its own Argo CD**, which reconciles only that cluster from GitHub with the same `gitops/apps` app-of-apps and sync waves as today, so nothing in dev or staging can deploy to prod. CI uses **GitHub OIDC to assume short-lived roles** (no AWS keys), pushes signed, immutable images to **ECR**, and promotes by Git change as it does today. Traffic enters through an **ALB with ACM certificates and WAF**, managed by the AWS Load Balancer Controller, and goes to **Envoy Gateway**, which keeps the Gateway API routes, the `/admin` 403 and the canary weights. **Route 53 records come from ExternalDNS**. Secrets come from **Secrets Manager through External Secrets**, encrypted with per-account KMS keys. **Datadog** replaces Prometheus, Loki, Alertmanager and Grafana for metrics, logs, APM, SLOs, monitors, dashboards and synthetics. The app keeps its Prometheus-format `/metrics`, which the Datadog Agent scrapes as OpenMetrics, so `app/server.js` stays unchanged. Prod finally runs the **Argo Rollouts canary**, with analysis driven by Datadog.

One account, one VPC, one EKS cluster and one Argo CD per environment. Nothing is shared between environments except the images in ECR and the Git repo.

```mermaid
flowchart TB
  dev([Developer]) -->|PR| gh[(GitHub<br/>orders-gateway-platform)]
  gh -->|Actions: test, build, Trivy,<br/>cosign keyless| ci[GitHub Actions]
  ci -->|OIDC AssumeRole<br/>no long-lived keys| ecr

  subgraph org [AWS Organization]
    subgraph sec [Security OU]
      logarch[Log archive acct<br/>CloudTrail org trail, Config]
      secacct[Security acct<br/>GuardDuty, Security Hub, Inspector admin]
    end
    subgraph shared [Shared-services acct]
      ecr[(ECR: immutable tags,<br/>Inspector scan, lifecycle,<br/>org-wide pull, DR-region replica)]
      r53root[Route 53 apex zone]
    end
    subgraph wl [Workloads OU]
      subgraph devacct [dev acct]
        devvpc[VPC 3 AZ<br/>1 NAT] --- deveks[EKS dev + its Argo CD<br/>Karpenter, Spot]
      end
      subgraph stgacct [staging acct]
        stgvpc[VPC 3 AZ<br/>1 NAT] --- stgeks[EKS staging + its Argo CD]
      end
      subgraph prodacct [prod acct]
        prodvpc[VPC 3 AZ<br/>NAT per AZ, endpoints] --- prodeks[EKS prod + its Argo CD<br/>Rollouts canary]
        alb[ALB + ACM + WAF] --> envoy[Envoy Gateway x2+] --> app[orders-gateway pods]
        sm[(Secrets Manager + KMS)]
      end
    end
  end

  gh -->|each Argo CD pulls<br/>its own environment| deveks & stgeks & prodeks
  ci -.->|scheduled: patch promoter,<br/>gates read Datadog| dd
  users([Users]) -->|Route 53 via ExternalDNS| alb
  deveks & stgeks & prodeks -->|Datadog Agent: metrics,<br/>logs, traces| dd[(Datadog<br/>SLOs, monitors, dashboards,<br/>synthetics)]
  dd -->|pages| pd[PagerDuty or Datadog On-Call]
  dd -->|tickets| chat[Slack / Jira]
  dd -.->|synthetic checks| alb
  ecr -->|pull| deveks & stgeks & prodeks
```

---

## 2. Local component to production replacement

| Local (repo reference) | Production | Why |
| --- | --- | --- |
| `docker-compose.yml`, the `ready` service and toolbox (`toolbox/`, `scripts/up.sh`) | Terraform roots run from CI, plus a one-off Argo CD install in each cluster | Compose exists locally to give one command and a health signal. In production the cluster's lifecycle belongs to IaC with reviewed plans. **Keep Compose and kind as the local dev loop and as the PR integration test** (`platform.yml`'s cluster job). |
| kind, 1 control plane + 2 workers, fake zones (`cluster/kind.yaml`) | EKS per environment, 3 real AZs, Karpenter on Graviton | Managed control plane, real failure domains |
| dev/staging/prod as namespaces in one cluster (`gitops/apps/templates/{dev,staging,prod}.yaml`) | One cluster per environment, each in its own account | Blast radius, IAM separation, separate upgrade cadence. Not a shared non-prod cluster: dev and staging get the same isolation as prod |
| In-stack Git server, soft-serve (`gitops/manifests/git-server/`) | GitHub only (today's "GitHub mode") | Its only purpose was offline use |
| Root Application applied by `./platform up` (`gitops/root.yaml`) | The same root Application, created by Terraform in each cluster with that cluster's values | Keeps the app-of-apps and sync waves unchanged |
| `./platform ship` / `rollback` with `kind load` | Promotion PRs and revert PRs. `localhost/` images are not admitted | Only CI-built, signed images run |
| GHCR (`cd-app.yml` `IMAGE: ghcr.io/...`) | ECR in shared-services. Optionally dual-push to GHCR during migration | IAM-native pulls, no external dependency in the data path, Inspector scanning |
| cosign keyless + BuildKit SBOM | Keep. Change the registry glob and the identity in `policies/verify-image-signatures.yaml` | Already the right design |
| Kyverno, 1 replica, `failurePolicy: Ignore` | Kyverno, 3 replicas, `Fail` for app namespaces, every policy on Enforce | What production needs |
| Envoy Gateway on NodePorts, 1 proxy | ALB (LBC, ACM, WAF) to Envoy Gateway, 2+ proxies across AZs with a PDB | WAF and ACM need an ALB. Envoy keeps HTTPRoutes and the `/admin` filter, and works with Argo Rollouts' Gateway API plugin |
| cert-manager + demo CA, `*.localtest.me` | ACM for public certificates. cert-manager only for the ALB→Envoy hop | ACM renews itself, and it's free on ALB |
| No DNS | Route 53, a delegated subzone per env account, ExternalDNS per cluster | |
| Sealed Secrets with a committed demo key | External Secrets Operator + Secrets Manager + KMS | The standard production path |
| kube-prometheus-stack, Prometheus 24 h | Datadog Agent + Cluster Agent (Datadog Operator). Keep metrics-server for the HPA | See §3.8. 15 months of metrics, so the real 30-day error budget can be computed (locally, 24 h) |
| Loki + Alloy | Datadog Logs, prod indexed, archives in S3 | |
| Grafana + `dashboards/*.json` | Datadog dashboards as code (Terraform `datadog` provider) | |
| `alerts/*.yaml` PrometheusRules + promtool tests | Datadog SLOs + burn-rate monitors + regular monitors, as code. Tests become fire drills in staging (§3.9) | |
| Alertmanager → `alert-receiver` | Datadog monitors → PagerDuty (or Datadog On-Call) for pages, Slack/Jira for tickets | |
| `runbooks/*.md` | Keep in Git. Every monitor message links to one. Rewrite the PromQL/LogQL sections as Datadog queries | |
| Trivy in CI, `rescan.yml` | Keep Trivy as the CI gate. Replace the daily rescan with Inspector continuous ECR scanning | Inspector re-scans when a new CVE is published |
| Trivy Operator | Drop. Use Inspector for images and Kyverno Enforce for config | Cuts duplicate tooling. *(Alternative: Datadog Cloud Security if it's licensed)* |
| NetworkPolicies on kindnet | VPC CNI network-policy enforcement (an EKS add-on option). Same policies, plus default-deny egress | FQDN egress needs Cilium or Network Firewall (§3.13) |
| `local-path` volumes | gp3 EBS through the CSI driver. Almost nothing stateful is left once Prometheus and Loki go | |
| Rolling updates only (no canary) | Argo Rollouts canary in prod, analysis through Rollouts' Datadog provider | Every prod release should be a canary |
| Patch promoter CronJob with a fine-grained token | A scheduled GitHub Actions workflow. Gates read the Datadog SLO and monitor APIs, including each cluster's Argo CD health. Token from a GitHub App | It holds no cluster credentials, so it can't become a cross-cluster admin |
| Trickle Deployment (`gitops/manifests/promoter/trickle.yaml`) | Keep it in dev/staging. In prod use Datadog Synthetics plus real traffic | |
| `admin` / `admin12345` | SSO everywhere (IAM Identity Center + IdP) | |
| `promotion/PAUSED` | Keep. Add Argo CD sync windows for prod freezes | |
| Renovate | Keep. Add Terraform providers and modules | |

---

## 3. Areas

### 3.1 Accounts and networking

**Recommend:**
- **AWS Organizations with OUs `Security` (log-archive, security-tooling), `Infrastructure` (shared-services), `Workloads` (dev, staging, prod) and `Sandbox`.** Use Control Tower if the owner wants guardrails and Account Factory ready-made. Otherwise plain Organizations plus Terraform (lighter, and nothing hidden). For a one-service platform I'd use plain Organizations and a dozen SCPs. *(Either is fine. Control Tower adds Config rules and cost.)*
- **SCPs:** deny regions other than the chosen one (plus us-east-1 for global services); deny leaving the org; deny disabling CloudTrail, GuardDuty, Config or Security Hub; deny `iam:CreateUser`/`CreateAccessKey` outside a break-glass path; deny the root user; require IMDSv2 on `ec2:RunInstances`.
- **One VPC per environment account.** Allocate non-overlapping CIDRs from VPC IPAM (e.g. dev 10.40/16, staging 10.41/16, prod 10.42/16) so peering or a TGW stays possible.
  - 3 AZs. **Public** /24s hold only the ALB and the NAT gateways. **Private** /19s hold the nodes and pods. Add an **intra** /24 set (no route to the internet) for the EKS control-plane ENIs.
  - **VPC CNI with prefix delegation** for pod density. If IPs get tight, add a secondary 100.64.0.0/16 CIDR for pods (custom networking). It isn't needed at this scale.
  - **NAT:** one per AZ in prod (a single NAT is a single-AZ dependency for egress, including Datadog and image pulls), one shared in dev and staging. The sketch already does this (`one_nat_gateway_per_az = var.env == "prod"`).
  - **VPC endpoints:** the S3 gateway endpoint everywhere (free; ECR layers come from S3). Interface endpoints for `ecr.api`, `ecr.dkr`, `sts`, `secretsmanager`, `kms`, `logs` and `ec2` **in prod only**. Each costs roughly $7–8 per AZ per month *(unsure: check the price)*, so ~7 endpoints × 3 AZs in prod is about $150/month (it would be ~$450 with them in all three VPCs). In dev and staging, NAT is cheaper. Consider **Datadog PrivateLink** in prod if it's available for the chosen Datadog site and region *(unsure: PrivateLink isn't offered for every site, and the EU1 site lives in GCP)*.
  - **VPC Flow Logs** to the log-archive account's S3 (cheaper than CloudWatch). Only send samples to Datadog.
- **No cross-VPC connectivity for deploys.** Each Argo CD talks only to its own cluster's API, so every cluster keeps `endpoint_public_access = false`, as the sketch has it, with no Transit Gateway or peering. Engineers reach the private endpoints and internal UIs through **AWS Client VPN** (one endpoint per account, SSO-authenticated) or SSM Session Manager. Add a Transit Gateway only when a second region or shared VPC services arrive.

**Options considered:** a single account with env-tagged resources (rejected: no IAM blast-radius boundary, and cost attribution by tags only). A shared non-prod account and cluster holding dev and staging (rejected: it would save ~$300–400/month, but dev and staging should get the same isolation as prod).

**Decided: one account and one cluster per environment.** The subnets also get an **isolated tier per AZ** (no route to the internet) for future data stores.

**Repo changes:** new `infra/` tree (§4). README's "Local vs a real cloud" table gets a link to this doc.

### 3.2 EKS and compute

**Recommend:**
- **Clusters: one per environment account (dev, staging, prod), each with its own Argo CD.** Everything below applies to each cluster. Private API endpoint. Access entries, not the `aws-auth` ConfigMap (the sketch already does this). Control-plane logs (`api`, `audit`, `authenticator`) to CloudWatch with 30-day retention, forwarded to Datadog only if Cloud SIEM is bought.
- **Compute: a small managed node group `system`** (2× `m7g.large`, Bottlerocket or AL2023 ARM, tainted `CriticalAddonsOnly`) for CoreDNS, Karpenter, LBC, ExternalDNS, ESO, Kyverno, Argo CD and the Datadog Cluster Agent. **Karpenter** NodePools provide the rest:
  - `apps`: on-demand in prod, Spot plus on-demand fallback in dev/staging, Graviton families `m7g`/`c7g`/`m8g`, consolidation `WhenEmptyOrUnderutilized`, disruption budgets restricted in prod business hours.
  - This replaces the sketch's fixed `platform` and `apps` node groups. Karpenter bin-packs better, and **Datadog bills per host**, so fewer, larger nodes save money twice (§3.12).
- **EKS Auto Mode** is a serious alternative. AWS then runs Karpenter, the VPC CNI, EBS CSI and the LB controller for you, at a per-instance management fee (roughly +12% on EC2 *(unsure)*). **Recommend standard EKS + Karpenter**: the team already runs every one of those controllers through GitOps, and Auto Mode's LB controller is less configurable. Re-evaluate if nobody wants to own the add-on upgrades.
- **Managed add-ons** through Terraform: vpc-cni (with `enableNetworkPolicy`), coredns, kube-proxy, eks-pod-identity-agent, aws-ebs-csi-driver, metrics-server *(unsure: metrics-server is available as an EKS community add-on; otherwise keep the existing Argo CD Application, minus `--kubelet-insecure-tls`)*.
- **The app's sizing stays as charted:** 100m request, no CPU limit, 128Mi memory limit, HPA 3–6 at 70% (`charts/orders-gateway/values.yaml`). Raise `maxReplicas` in prod (e.g. 12) now that Karpenter can add nodes. 6 was the laptop's ceiling.
- **Upgrades:** follow EKS standard support. Avoid extended support (it costs 6× more for the control plane). Upgrade dev, then staging, then prod a week apart. For big jumps, build a new cluster blue/green from the same Terraform module and GitOps, then shift Route 53 weights. Statelessness makes this cheap.

**Repo changes:** `gitops/values/*` gain an EKS layer (`gitops/values/eks/<component>.yaml`, as the sketch's `root.yaml` comment foresees): storage classes, tolerations for `system`, LBC/ExternalDNS/ESO/Karpenter Applications, and the removal of kind-only bits (metrics-server's insecure TLS, NodePort pins in `gitops/manifests/gateway/envoyproxy.yaml`).

### 3.3 Identity: IAM, Pod Identity, Kubernetes RBAC, SSO

**Humans:**
- **IAM Identity Center**, federated to the company IdP (Okta, Entra or Google; open question). Permission sets: `PlatformAdmin` (admin in dev and staging, break-glass-only in prod), `Developer` (read-only in prod, power-user in dev), `ReadOnly`, `Billing`. No IAM users anywhere. A sealed break-glass role in each account, with alarms on use.
- **EKS access entries** map Identity Center roles to clusters. `PlatformAdmin` gets `AmazonEKSClusterAdminPolicy`. `Developer` gets `AmazonEKSViewPolicy` in prod and `AmazonEKSEditPolicy` scoped to the app namespace in dev. In prod, writes go through Git only: Argo CD self-heal already undoes `kubectl edit` (README "When it's broken").
- **Argo CD SSO:** OIDC against the IdP (Dex or direct OIDC). Argo CD RBAC maps IdP groups to AppProject roles: devs may sync and roll back the `dev` app in dev, and nobody but the platform group may touch platform apps in prod. Disable the local `admin` account.
- **Datadog SSO** through SAML with the same IdP, roles mapped from groups.

**Workloads: recommend EKS Pod Identity over IRSA for new roles.**
| | Pod Identity | IRSA |
| --- | --- | --- |
| Setup | One agent add-on, `aws_eks_pod_identity_association` in Terraform | An OIDC provider per cluster, a trust policy that names the cluster's issuer |
| Reuse across clusters | The same role works in any cluster (trust is `pods.eks.amazonaws.com`) | A new trust entry per cluster |
| Session tags | Yes (cluster, namespace, SA), usable in ABAC policies | No |
| Support | Most AWS SDKs and controllers today *(unsure: check each controller's minimum SDK version)* | Universal |

Roles, one per controller per cluster, least privilege:
- **AWS Load Balancer Controller:** the upstream policy. Scope tag conditions to `elbv2.k8s.aws/cluster = <name>` where the policy allows.
- **ExternalDNS:** `route53:ChangeResourceRecordSets` on **that env's hosted zone only**, plus `ListHostedZones`.
- **External Secrets:** `secretsmanager:GetSecretValue`/`DescribeSecret` on `arn:...:secret:ogp/<env>/*`, and `kms:Decrypt` on the env CMK through the `kms:ViaService` condition.
- **Karpenter:** the controller policy scoped to the cluster's tags, plus a node role.
- **EBS CSI:** the managed policy.
- **cert-manager:** none if ACM handles public certs (the sketch's DNS-01 role then goes away).
- **The app:** **no AWS role at all**, and `automountServiceAccountToken: false` as today.
- **Argo CD:** no AWS role. It manages only its own cluster through its in-cluster service account, so no cross-account role exists that could deploy to prod from elsewhere. Its repo credential is a read-only GitHub App installation (or deploy key) per cluster.

**CI (GitHub Actions to AWS):**
- An IAM OIDC provider for `token.actions.githubusercontent.com` in shared-services and in each env account (only where CI needs it).
- `gha-ecr-push` (shared-services): trust `sub = repo:iantest11111989/orders-gateway-platform:ref:refs/heads/main` and `aud = sts.amazonaws.com`. Permissions: `ecr:PutImage`, `InitiateLayerUpload` and friends on `orders-gateway` only. **No delete or tag-mutation rights.** PRs get no role; they build without pushing, as `ci-app.yml` already does.
- `gha-tf-plan-<acct>`: read-only plus the state bucket, trusted for `pull_request` events. `gha-tf-apply-<acct>`: trusted for `environment:<env>` only, so prod applies need the GitHub Environment's required reviewers.
- **CI never talks to a cluster.** Argo CD pulls, so no kube credentials exist in GitHub at all. That's the strongest property the repo already has; keep it.
- Replace the promoter's fine-grained PAT and the `GITHUB_TOKEN` PR-opening trick with a **GitHub App** whose private key lives in Secrets Manager (shared-services account). Production needs individual human and bot identities, or approvals mean nothing.

**Repo changes:** `charts/orders-gateway/templates/serviceaccount.yaml` is unchanged. New Terraform modules `pod-identity`, `github-oidc`. `gitops/values/argocd.yaml` gains OIDC, RBAC and HA.

### 3.4 Images and supply chain

**Recommend:**
- **ECR in shared-services**, repository `orders-gateway`:
  - **Tag immutability ON.** This breaks today's practice of re-pushing `v1`/`v2` from every main commit. Move the demo images to a separate `orders-gateway-demo` repository with mutable tags, never admitted in prod. Immutability still allows *adding* a tag to an existing digest, which promotion uses below.
  - **Enhanced scanning (Inspector), continuous** on `orders-gateway`, scan-on-push on the rest. Findings go to Security Hub and Datadog. This replaces `rescan.yml`'s daily job; keep `rescan.yml` until Inspector has run in parallel for a month.
  - **Lifecycle:** expire untagged manifests after 7 days *(careful: cosign v3 bundles and BuildKit SBOM manifests are referrers/index children. Check that the lifecycle rules don't treat them as untagged orphans. Unsure; test it in dev first.)* Keep the last 100 `sha-*` images. Never expire `release-*`, which the promotion job adds to a digest when it reaches prod.
  - **Encryption** with a shared-services KMS CMK. The repo policy grants pull to the org (`aws:PrincipalOrgID` plus the `Workloads` OU path condition) for the node roles. **Cross-account pull, not replication, within one region.** Cross-region **replication** only to the DR region (§3.11).
  - **Pull-through cache** rules for `docker.io`, `quay.io`, `registry.k8s.io`, `ghcr.io` and `public.ecr.aws`, so third-party charts' images come through ECR. That removes the rate-limit failure mode in the README's troubleshooting table, and Inspector scans them too. Kyverno's `restrict-image-registries` then allows **only** `<shared-acct>.dkr.ecr.<region>.amazonaws.com/` (plus a few exceptions while migrating). The sketch has the GHCR rule. Docker Hub needs credentials in Secrets Manager.
- **The Helm chart lives in the cloud too, not only in Git.** Locally a chart version is just the chart in this repo. In production CI publishes each chart version to a **chart repository in shared-services**:
  - **ECR as an OCI registry** is the usual AWS choice: repository `charts/orders-gateway`, `helm push oci://<acct>.dkr.ecr.<region>.amazonaws.com/charts`. Argo CD reads OCI charts natively, the tags are immutable, pulls go through the same cross-account IAM as the images, and Inspector and lifecycle rules apply as above.
  - **S3 with the `helm-s3` plugin** also works (a versioned bucket as a classic Helm repo), but Argo CD then needs a plugin or a proxy to read it. Prefer ECR.
  - Either way, CI publishes only when the chart's version goes up and refuses to overwrite a version, cosign signs the chart by digest, and staging and prod each pin a chart version alongside the image, promoted by the same PRs (§3.5).
- **Signing: keep cosign keyless**. It's free and keyless, and the identity check (`cd-app.yml@refs/heads/main`, `policies/verify-image-signatures.yaml`) is exactly the right policy. ECR supports the OCI 1.1 referrers API that cosign v3 bundles use *(unsure: confirm with a real push, because Kyverno 1.20's referrer lookup was only verified on GHCR)*. Alternatives:
  - **AWS Signer + Notation:** AWS-native, but Kyverno's Notary verification is less mature, and the signing key moves to AWS. Not worth the switch.
  - **cosign with a KMS key:** removes the dependency on public Sigstore (Fulcio/Rekor) at admission. Worth it if the org won't accept public transparency-log entries naming its repo. Open question.
- **Add SLSA build provenance** (`actions/attest-build-provenance` or `cosign attest --type slsaprovenance`), and have Kyverno require it in prod. Keep the BuildKit SBOMs.
- **Admission:** Kyverno HA (3 replicas, PDB, `system` node pool), **`failurePolicy: Fail`** on the image policies in the app namespaces. Exclude `kube-system` and `kyverno` as today. Turn on the background and reports controllers so already-running pods are re-checked (closing the gap where a pod created while Kyverno is down stays running). Every Audit policy in `policies/` moves to Enforce once clean,.
- **CI changes in `.github/workflows/cd-app.yml`:** `aws-actions/configure-aws-credentials` with the OIDC role, then `aws-actions/amazon-ecr-login`. Push by digest, sign, verify, and fail on an empty SBOM, as now. During migration, push to both GHCR and ECR. `promote-dev` writes the ECR repository into `environments/dev/values.yaml`, and `scripts/set-image.sh` learns a repository argument.

### 3.5 GitOps and promotion across clusters

**Decided: one Argo CD per cluster, so one per environment.** Each Argo CD manages only the cluster it runs in.

| | Chosen: Argo CD in every cluster | Not chosen: one hub managing every cluster |
| --- | --- | --- |
| Blast radius | Smallest: a compromised dev or staging Argo CD can't touch prod | The hub holds admin on every cluster |
| Network | Nothing across VPCs: each Argo CD uses its own cluster's API | The hub needs private access to every cluster's API |
| Operations | Three Argo CDs to upgrade, three UIs, three SSO configs, all from the same Git and Terraform | One of each |
| Cross-environment view | GitHub Deployments and a Datadog dashboard (below) | One UI |
| Argo CD outage | Only that environment's deploys stop | Deploys stop everywhere |

Argo CD Agent (one UI, agents pulling in each cluster) was also considered. Revisit it if three UIs become a burden.

**How each cluster's Argo CD is set up:**
- Terraform installs it once per cluster (HA, SSO through the IdP) together with the root Application. After that Argo CD manages its own release, as it does locally.
- The root renders the existing `gitops/apps` chart with this cluster's values: `{env, aws: {...}}`, carrying Terraform's outputs (role ARNs, the ACM cert ARN, the WAF ACL ARN, the hosted zone, the cluster name). Templates keep `destination.server: https://kubernetes.default.svc`, so **the app-of-apps and its sync waves work as they do locally**.
- Only that environment's Application is on: the dev cluster runs `orders-gateway-dev`, prod runs `orders-gateway-prod`. That needs one small change: a guard in each environment's Application template that renders it only when `env` is unset or matches. Locally `env` is unset, so the three run side by side in one cluster, under the same names.
- RBAC per Argo CD: developers can sync dev; the release group syncs staging and prod. Prod also gets sync windows (no syncs outside working hours unless labelled `hotfix`).
- One AppProject per Argo CD restricts sources to this repo and destinations to the cluster's own namespaces.
- `gitops/values/` splits into `base/` (today's files minus kind-isms), `eks/`, and per-env overrides where needed (e.g. `gitops/values/prod/karpenter.yaml`).

**One view across environments.** With no hub, two things show dev, staging and prod side by side. **argocd-notifications** in each Argo CD reports its syncs to GitHub as **Deployments** for its environment (its GitHub service has a `deployment` template, triggered on sync succeeded, failed and degraded), so the repo's **Environments** panel shows what each environment runs and since when. And the Datadog Agent's Argo CD integration puts every Application's sync and health on one Datadog dashboard.

**Three repositories, not one.** Locally everything is in this repo for convenience. In production the app's code doesn't live with the cluster config:

| Repo | Holds | Who can merge |
| --- | --- | --- |
| `orders-gateway` (app) | `app/`, the Helm chart, and CI that tests, builds, signs and publishes the image and the chart | The app's developers |
| `orders-gateway-deploy` (GitOps) | What Argo CD syncs: the per-environment files that pin image and chart versions, plus the cluster-wide `system/` components | The platform team; promotion PRs need the release group for prod |
| `orders-gateway-infra` (Terraform) | Accounts, networks, clusters, IAM (§4) | The platform team |

Why: app developers can't change cluster-wide config by accident, each repo has its own history and reviewers, and the app repo's CI never writes cluster config directly. It only opens promotion PRs in the deploy repo, through a GitHub App installed there with pull-request rights only. Argo CD reads only the deploy repo and the chart registry. The promotion steps below happen in the deploy repo.

**Promotion across clusters: a Git change.**
- `main` merge → CI builds, signs and pushes to ECR → the `promote-dev` commit edits `environments/dev/values.yaml` → dev's Argo CD syncs it.
- Staging and prod move by **promotion PR** (`promote/staging`, `promote/prod`). Each changes only that environment's image line, pinned to **digest + tag**, so the same image moves through every environment without a rebuild.
- **The patch promoter** merges a patch PR once the previous environment has soaked: an hour on that exact digest, its SLO met, no alerts, its Application Synced and Healthy. Features wait for an owner approval. It runs as a **scheduled GitHub Actions workflow** and reads only Datadog (the SLO status API, the monitor search API, metric queries for request count and version, and each cluster's Argo CD health as the Agent reports it) and GitHub, so it holds no cluster credentials. Its GitHub credential is a GitHub App. A `promotion/PAUSED` file stops it.
- **Patch or feature** is worked out by CI when it opens the promotion PR, from the commits in the range: a `Promotion-Kind: patch|feature` commit trailer, or conventional commits (`fix:` vs `feat:`). Only patches are auto-merged.
- The prod PR also gets a required status check from a post-deploy staging smoke and load job (§3.9).
- **Kargo** (Akuity) was considered: it models "freight" moving through stages, with verification. It's nice, but it duplicates what the promoter and promotion PRs do and adds a controller. Revisit with many services.

### 3.6 Ingress, DNS and TLS

**Options:**
| | ALB Ingress straight to the app (LBC) | NLB → Envoy Gateway | **ALB → Envoy Gateway (recommended)** | LBC's own Gateway API support |
| --- | --- | --- | --- | --- |
| WAF | Yes | **No** (WAF doesn't attach to an NLB) | Yes | Yes for ALB-backed Gateways |
| ACM certs | Yes | Yes (TLS listener) | Yes | Yes |
| `/admin` 403, path filters | ALB listener rules (annotation JSON) | Envoy `HTTPRouteFilter` | Both: WAF rule + Envoy filter | Gateway API, limited filters *(unsure)* |
| Canary traffic split | Rollouts ALB provider (weighted target groups) | Gateway API plugin | Gateway API plugin, unchanged | Gateway API plugin *(unsure if supported)* |
| Keeps the repo's routes and tests | No, rewrite as Ingress | Yes | Yes | Mostly |
| Extra hop and cost | none | NLB | ALB + Envoy pods | none |

**Recommend ALB → Envoy Gateway.** WAF in prod is non-negotiable, and Envoy keeps every Gateway API route, the `/admin` filter, the JSON access logs, and Argo Rollouts' Gateway API plugin can split its traffic for canaries. The ALB is created by LBC from a small `Ingress` (class `alb`) in `envoy-gateway-system`, with Envoy's Service as default backend (IP targets). Annotations:

- `certificate-arn` (or ACM auto-discovery by host), `wafv2-acl-arn`, `ssl-policy` = a TLS 1.2/1.3 policy, `ssl-redirect`
- `healthcheck-path` against Envoy's ready endpoint
- `load-balancer-attributes: deletion_protection.enabled=true`, access logs to S3
- `external-dns.alpha.kubernetes.io/hostname` for the record

**Alternative: NLB → Envoy, with an ALB only if WAF is needed.** Envoy Gateway's `EnvoyProxy` Service becomes an internet-facing **NLB** through the AWS Load Balancer Controller (IP targets, cross-zone). TLS terminates **at Envoy**, with certificates from cert-manager and Let's Encrypt DNS-01 through Route 53. That keeps today's design closest: the same Gateway, listeners, HTTPRoutes, the `/admin` 403 filter and the path-normalising `ClientTrafficPolicy`, with one fewer hop. **Recommend:** both keep Envoy and every route. The only question is whether the edge needs AWS WAF, which only attaches to an ALB, CloudFront or API Gateway. A public `orders` API should have WAF (managed rule groups, rate limits, body-size limits), so **prod gets ALB → Envoy and non-prod can use NLB → Envoy**. If the owner decides prod doesn't need WAF, NLB everywhere is simpler.

Envoy's `EnvoyProxy` (`gitops/manifests/gateway/envoyproxy.yaml`) becomes `ClusterIP` with `replicas: 3`, topology spread across AZs and a PDB (the README's "What we'd do next" #1). Watch out: the ALB's idle timeout (60 s) must stay **below** Envoy's and the app's keep-alive (`server.keepAliveTimeout = 65000` in server.js, so that already holds) to avoid 502s on reused connections.

*Considered:* making LBC's Gateway API implementation the only proxy (drops Envoy). It's attractive once its filter support and the Rollouts plugin's compatibility are confirmed *(unsure)*. Not now.

**Edge rules for prod. These are stricter than local on purpose:**
- **Only route the app's real paths:** `/work`, `/echo` (POST), `/version`. Return 404 at Envoy for everything else, including **`/metrics`, `/healthz` and `/readyz`, which the local edge forwards today**.
  - Reason one: `/metrics` leaks internals.
  - Reason two: **server.js keys its in-memory counters and histograms by the raw path** (`route = url.pathname`, then `inc()`/`observe()` for every non-probe request, 404s included). A scanner hitting random URLs grows the process's memory without bound until the 128Mi limit OOM-kills the pod. The ServiceMonitor only drops those series at scrape time, so it protects Prometheus, not the pod. Filtering unknown paths at the edge is the only fix that leaves server.js unchanged. *(Worth confirming with a soak test, §3.9.)*
- WAF: AWS managed rule groups (Common, KnownBadInputs, IP reputation, Anonymous IP optional). A rate-based rule per IP. A body-size limit on `POST /echo` (the app reads the whole body into memory). An explicit block of `/admin*`.
- Shield Standard comes free. Shield Advanced (~$3k/month) only if the business case exists.

**DNS:**
- An apex zone (e.g. `example.com`, open question) in shared-services. Delegate `dev.orders.example.com` and `staging.orders.example.com` hosted zones to the dev and staging accounts. Prod's `orders.example.com` lives in the prod account.
- **ExternalDNS per cluster**, `--domain-filter` set to its own zone, `--txt-owner-id=<cluster>`, `policy: upsert-only` in prod (no deletes), sources `ingress` + `gateway-httproute`.
- For blue/green clusters or DR, use weighted or failover records with Route 53 health checks, managed by Terraform (not ExternalDNS) for the apex.

**TLS:**
- **Public:** ACM certificates (DNS validation in the env zone, from Terraform), attached to the ALB. Free and auto-renewed. The sketch's cert-manager + Let's Encrypt DNS-01 isn't needed at the edge.
- **ALB → Envoy:** HTTPS with a cert from cert-manager's in-cluster CA (ALB doesn't validate backend certs, so this protects the bytes in the VPC without a PKI). Keep cert-manager. Drop `gitops/manifests/gateway/ca.yaml`'s demo naming. AWS Private CA (~$400/month per CA *(unsure)*) isn't worth it here.
- **Internal UIs** (each cluster's Argo CD, the Rollouts dashboard): an internal ALB per cluster, reached over Client VPN, with SSO. Grafana, Prometheus and Alertmanager disappear with Datadog.

### 3.7 Secrets

**Recommend External Secrets Operator + AWS Secrets Manager, per-account KMS CMKs.**
- **What actually needs secrets?** The app has none (server.js reads only `VERSION`, `PORT`, `STARTUP_DELAY_MS` and `FAULT_*`). The platform needs: the Datadog API key (per cluster), the GitHub App key for Argo CD repo access (hub), the promoter's GitHub App key (hub), Docker Hub creds for the pull-through cache (shared-services), and the PagerDuty/Slack integration keys (stored in Datadog, not Kubernetes). So: **few secrets, low churn**.
- Path convention `ogp/<env>/<component>/<name>`, matching the sketch's IAM scope. One `ClusterSecretStore` per cluster, authenticated by Pod Identity. `ExternalSecret`s live next to their component in `gitops/manifests/<component>/`. Refresh at 1 h.
- KMS: one CMK per account for Secrets Manager, one for EKS envelope encryption of Kubernetes Secrets (the cluster's `encryption_config`), one for EBS, one for ECR, plus the Terraform state key. Key policies grant use to specific roles only. Automatic rotation on.
- Rotation: Datadog API keys rotated by hand yearly, with a runbook. GitHub App private keys every 90 days (two keys valid during overlap).

**Options considered:**
- **Sealed Secrets with the key kept out of Git** : workable, but key backup, rotation and per-cluster re-sealing become our problem. With per-account clusters, each needs its own sealing cert.
- **SSM Parameter Store SecureString:** free standard tier vs ~$0.40/secret/month for Secrets Manager. ESO supports both. With fewer than 20 secrets the cost is noise, and Secrets Manager adds rotation and cross-region replicas (DR).
- **Secrets Store CSI driver:** mounts files rather than Kubernetes Secrets. Better for "never in etcd", but Datadog/Argo CD want Secret objects.

**Repo changes:**
- Delete `gitops/manifests/sealed-secrets/` and the `sealed-secrets` Application. Remove the demo-key exception from `scripts/check-no-plain-secrets.sh`, and keep the check itself.
- Grafana's SealedSecret goes away with Grafana.
- New `gitops/apps/templates/external-secrets.yaml` (wave 10) and a `cluster-secret-store` manifest (wave 15).
- Runbooks `SealedSecret*.md` are replaced by `ExternalSecretSyncFailed.md`.

### 3.8 Observability with Datadog

**Options:**
| | A. Datadog everything (recommended) | B. Hybrid: Datadog APM/logs + AMP/AMG for metrics | C. AWS-native OSS: AMP + Amazon Managed Grafana + CloudWatch/OpenSearch or Loki-on-S3 |
| --- | --- | --- | --- |
| Cost at this size | Highest. Billed per host, per GB, per custom metric | Medium, and two bills | Lowest |
| Lock-in | High for dashboards/monitors. Low for instrumentation if kept OTel/OpenMetrics | Medium | Low. PromQL, rules and promtool tests are reused as-is |
| Effort | Low: one Operator, everything correlated | Two systems to correlate | Highest to operate (Loki, Grafana alerting) |
| On-call ergonomics | Best: SLOs, burn-rate alerts, synthetics, APM, log/trace correlation, incident tooling | Split | Fine |
| Reuse of repo assets | Rewrite dashboards and alerts | Partial | Almost all |

**Recommend A**, because the owner wants Datadog and the value is in one correlated pane for on-call. Be honest about two points:
1. For **one tiny stateless service**, Datadog will likely cost more than the app's compute.
2. Option C keeps ~90% of the repo's observability work (`alerts/`, `dashboards/`, the promtool tests) untouched.

If cost or lock-in dominates, C is the defensible answer. Either way, **keep the instrumentation vendor-neutral**: Prometheus exposition from the app (unchanged), OpenTelemetry for traces, and W3C `traceparent` (which the app already logs).

**Deployment:**
- **Datadog Operator** from an Argo CD Application (wave 20). One `DatadogAgent` CR per cluster with:
  - Cluster Agent (2 replicas), the admission controller, kube-state-metrics core, the Orchestrator Explorer, log collection with container exclusions, APM, and OTLP ingest on.
  - The API key from ESO.
  - Tags `env:<env>`, `service:orders-gateway`, `version:<tag>` through Unified Service Tagging labels on pods (`tags.datadoghq.com/env|service|version`), added in the chart.
- **Remove:** kube-prometheus-stack, `prometheus-operator-crds`, Loki, Alloy, `alert-receiver`, `platform-alerts`, the Grafana dashboards ConfigMaps, and the ServiceMonitors (or keep the CRDs only if some chart needs them to render).

**App metrics, server.js unchanged:**
- Pod annotation for the OpenMetrics check (`ad.datadoghq.com/app.checks`), `openmetrics_endpoint: http://%%host%%:8080/metrics`.
- Metrics: `http_requests_total`, `http_request_duration_seconds`, `app_info`, `app_ready`, `app_inflight_requests`.
- `histogram_buckets_as_distributions: true`, so latency percentiles are computed server-side across pods.
- **Keep the route allow-list** in the check config, or the edge filter above, to bound custom-metric cardinality.
- Use Metrics without Limits to drop `pod_name` and `container_id` from the indexed tags on the counters (you query by env/route/status, not pod). This is the main custom-metrics cost lever.

**Logs:**
- The app's JSON lines parse automatically. Add a pipeline that remaps `status` → `http.status_code` and `duration_ms` → `duration`, plus a trace-id remapper on `trace_id`.
- Exclusion filters: drop the trickle (`cust-trickle`) and Envoy health checks.
- Indexes: prod 15 days. Dev/staging at 10–20% sampling, or Flex Logs. Archive everything to S3 in log-archive for 1 year (rehydrate on demand).

**Traces:**
- The app has no SDK and server.js must not change.
  - **Recommend Datadog's admission-controller library injection** (Single Step Instrumentation for Node). It adds `dd-trace` through an init container at pod start, with no image change. Enable it on the app namespace only, with `DD_TRACE_PROPAGATION_STYLE=tracecontext,datadog` so the incoming `traceparent` is honoured.
  - Alternative, more neutral: the OpenTelemetry Operator's Node auto-instrumentation, exporting OTLP to the Agent.
- Envoy Gateway can also emit OTLP spans for the edge hop.
- **Honest note:** the app makes no downstream calls (README, Limitations), so a trace is ~2 spans (Envoy + app). APM mainly buys per-request latency breakdowns, error tracking and log↔trace links, which is useful but not transformative here. APM is billed per host, so consider enabling it only in prod and staging.
- *(unsure: the injected tracer must not double-handle `traceparent`. Check that the app's logged `trace_id` matches the APM trace id in W3C mode.)*

**SLOs and burn-rate alerts (mapping today's rules):**
| Today (`alerts/orders-gateway-slo.yaml`) | Datadog |
| --- | --- |
| Availability SLI: 5xx on `/work`+`/echo` over non-4xx | **Metric-based SLO**, per env (`env` tag as the SLO's group, or one SLO per env). Good = `sum:http_requests_total.count{route IN (/work,/echo), !status:5*, !status:4*}`, total = the same without the `!status:5*`. Target 99.5% over 30 days (plus 7-day views) |
| Latency SLI: `/echo`+`/version` within 250 ms (`le="0.25"` bucket) | Metric SLO from the bucket counter: good = `http_request_duration_seconds.bucket{route IN (/echo,/version), upper_bound:0.25}`, total = `…count{route IN …}`. Exact, as locally *(unsure about the exact bucket tag name the OpenMetrics check emits; verify on the dev cluster)*. Or a time-slice SLO on p99 from the distribution, which is simpler but a different semantic. Prefer the ratio |
| Fast burn 14.4× over 1 h & 5 m, `severity: page` | **SLO burn-rate alert**, long window 1 h. Datadog uses a short window of 1/12 of the long, so 5 m, which matches. Threshold 14.4 → `@pagerduty-orders` |
| Slow burn 6× over 6 h & 30 m, `severity: ticket` | Burn-rate alert, long window 6 h (short 30 m), threshold 6 → `@slack-orders-alerts` + `@jira` |
| Platform/security alerts (`alerts/platform-delivery.yaml`, `platform-security.yaml`) | Monitors: Argo CD app health/sync (Argo CD metrics via the Agent's Argo CD integration in each cluster), Kyverno admission errors and denials, cert expiry (ACM's `DaysToExpiry` via the AWS integration, and cert-manager's for the internal cert), ExternalSecret sync failures, Inspector critical findings, Rollouts aborted, Karpenter provisioning failures |
| Watchdog / dead-man's switch | Datadog is the receiver now, so turn it around: **no-data monitors** on `http_requests_total` per env (the trickle and synthetics guarantee data), and an Agent-up monitor per cluster. Also a PagerDuty heartbeat fed by a Datadog synthetic, so that "Datadog can't page" is noticed *(optional)* |
| `runbook_url` annotation + a CI check that it exists (`scripts/test-alerts.sh`) | Every monitor message carries `Runbook: https://github.com/.../runbooks/<Name>.md`, and a CI check over the Terraform monitor definitions asserts the file exists. Keep the runbook names |
| promtool unit tests (`alerts/tests/`) | No equivalent offline test. Replace them with: (1) `terraform validate` plus Datadog's monitor validate endpoint in CI; (2) a **weekly fire drill in staging** that sets `FAULT_ERROR_RATE` (an in-cluster `POST /admin/fault`, which the edge blocks) and asserts that the fast-burn monitor goes to Alert within N minutes and recovers after reset. That tests the whole delivery path, which promtool never did |

**As code:** monitors, SLOs, dashboards, synthetics, log pipelines and indexes go in a Terraform root `infra/live/observability/` with the `datadog` provider. Alternative: the Datadog Operator's `DatadogMonitor`/`DatadogSLO`/`DatadogDashboard` CRDs through Argo CD, which keeps everything in GitOps, but CRD coverage lags the provider *(unsure)*. **Recommend Terraform**: a reviewed plan suits "what pages me" changes. Port `dashboards/orders-gateway.json` and `platform-overview.json` first. `argocd.json`, `kyverno.json` and `argo-rollouts.json` mostly come from Datadog's out-of-the-box integration dashboards. `budget.json` was laptop-specific and goes away.

**Cost (list prices, approximate, unsure, verify with Datadog):** Infrastructure Pro ~$15/host/month, APM ~$31/host/month, logs ~$0.10/GB ingested + ~$1.70 per million events indexed (15 days), custom metrics beyond the per-host allotment ~$5 per 100. With ~9 hosts (§3.12), infra + APM on 5 hosts + modest logs comes to roughly **$350–600/month**, before custom-metric overages.

### 3.9 Testing strategy

Principle: every promotion step requires evidence from the step before, collected automatically. server.js and server.test.js stay unchanged, and new tests live beside them (`app/tests/`, `tests/`).

| Test | What and tool | Where it runs | Gates |
| --- | --- | --- | --- |
| Unit | `node --test` (existing `app/server.test.js`) | PR, main | merge |
| Static | hadolint, shellcheck, actionlint, `helm lint` + `kubeconform` per env, `helm-unittest` for the chart's conditionals (HPA, PDB, publicRoute), `kyverno test policies/tests`, `tflint`/`checkov` (or `trivy config`) on `infra/`, `terraform validate` | PR | merge |
| API | Write an **OpenAPI spec** for the black box (`app/openapi.yaml`: `/work` incl. the `ms` cap at 2000, `POST /echo`, `/version`, 404 shape, 503 `/readyz` while draining). Run **Schemathesis** against the built container in CI (property-based, catches 5xx on odd inputs). Plus a hand-written **Hurl** or k6 suite for exact behaviours: the SIGTERM drain (`/readyz` → 503, in-flight finishes), `connection: close` while shutting down, the `ms` cap, invalid JSON on `/admin/fault` → 500 *(that last is a real server.js behaviour: `JSON.parse` throws into the catch)* | PR (on the image built in the `image` job) | merge |
| Integration | The existing kind cluster job (`platform.yml`): full `up`, `verify`, ship/rollback under traffic. Add an **EKS-layer render test**: `argocd app diff` preview, or [argo-cd-diff-preview](https://github.com/dag-andersen/argocd-diff-preview), posting rendered manifest diffs for every cluster on the PR | PR | merge |
| Terraform plan | `terraform plan` per affected root, plan posted to the PR (read-only OIDC role) | PR | merge; apply on main with an environment approval for prod |
| Smoke (post-deploy) | An Argo CD **PostSync hook Job** in each env (small image with `curl`/Hurl): hits the Service and the public hostname. `/version` must equal the expected tag, `POST /echo` round-trips, `/admin/fault` → 403 at the edge, `/metrics` → 404 at the edge (prod). A failed hook makes the sync Failed, which fires an Argo CD notification and a Datadog event | after every sync, every env | the promoter's gate: "last sync's smoke passed" |
| Synthetic monitoring | Datadog Synthetics: API tests every 1 min from 3 locations on prod (`GET /version`, `POST /echo` with assertions on latency < 250 ms), multistep for flows, a private location in staging. Monitor → page if 2 of 3 locations fail | continuous, prod + staging | prod health; also a promoter gate ("no failing synthetic in target env") |
| Canary analysis | Argo Rollouts AnalysisTemplate with the Datadog provider (§3.10) | prod releases | automatic abort/rollback |
| Load | k6 (existing `app/k6/load.js`) via the **k6 Operator** in staging: a nightly 15 min at 2× prod's peak rate, plus a weekly step test to find the knee (when the HPA saturates, p99 vs replicas). Thresholds as in load.js (`orders_slo_good >= 0.995`, p99 < 250 ms). Results sent to Datadog | nightly + before a feature promotion | **feature** promotion to prod requires the latest staging load run green on that image |
| Soak | 8–24 h in staging weekly at prod-like rate, **including a slice of random-path requests**, watching memory per pod (the unbounded-route-map risk in §3.6), event-loop lag, and fd counts | weekly; before major Node base-image upgrades | ticket on regression |
| Chaos | **AWS FIS** experiments: terminate a node, AZ power-interruption scenario, `ec2:stop` on Envoy's node, API throttling. In-cluster: pod kill, CoreDNS loss, Kyverno down (verifies fail-closed doesn't block rollbacks: an **open question**, because `Fail` + a Kyverno outage blocks new pods). Reuse `./platform demo chaos` logic, with the SLO gate at 99.5% | monthly game day in staging; quarterly in prod in business hours with stop conditions on the burn-rate monitors | findings become tickets |
| Security | Trivy (CI gate), Inspector (continuous), an OWASP ZAP baseline DAST against staging nightly | PR / nightly | critical findings block promotion (an Inspector finding on the target digest is a promoter gate) |
| Alert fire drill | The `/admin/fault` drill in staging (§3.8) | weekly | ticket if a monitor didn't fire |

**Testing the AWS resources themselves.** The table above tests the app and the platform. The AWS layer needs its own tests, because a wrong IAM policy or route table fails silently until something needs it:

| Test | Tool | When | What it catches |
| --- | --- | --- | --- |
| Static policy checks | `checkov` or `trivy config` on `infra/`, `tflint` with the AWS ruleset | every PR | public S3 buckets, unencrypted volumes, `0.0.0.0/0` security group rules, missing flow logs, IMDSv1 |
| IAM policy validation | IAM Access Analyzer `validate-policy` and `check-no-new-access` in CI (`aws accessanalyzer`), against every policy document Terraform renders | every PR touching IAM | wildcards, privilege escalation (`iam:PassRole` on `*`), a policy granting more than the previous version without review |
| Module tests | `terraform test` (native, 1.6+) with mocked providers for logic; Terratest for a real apply in a sandbox account, then destroy | PR for modules; nightly in sandbox | a module that plans but doesn't apply (quota, ordering, name collisions), outputs the GitOps bridge depends on |
| Plan review | `terraform plan` posted to the PR, with a check that fails on any `destroy` of a stateful or protected resource (`prevent_destroy` plus a plan-JSON check) | every PR | accidental cluster or VPC replacement from an innocent-looking change |
| Policy as code on the plan | OPA/conftest on the plan JSON | every PR | org rules: tags present, only approved regions and instance families, no public EKS endpoint |
| Post-apply smoke | a CI job after `apply` that asserts the live result with the AWS CLI: the EKS endpoint is private, nodes are Ready, every Pod Identity association resolves (a test pod per controller runs `aws sts get-caller-identity` and gets the expected role), ECR pulls work from each account, ExternalDNS can write only its own zone (a write to another zone is denied) | after every apply | permissions that look right on paper but don't work, cross-account trust mistakes |
| Drift | nightly `plan -detailed-exitcode`, opening an issue on drift | nightly | console changes, out-of-band fixes |
| Continuous compliance | AWS Config rules and conformance packs, Security Hub (FSBP, CIS) | continuous | regressions after deploy, resources created outside Terraform |
| Resilience | AWS FIS (see Chaos above), Route 53 failover tests for the DR record | monthly / quarterly | single-AZ dependencies (one NAT, one Envoy), untested failover |
| Cost | Infracost on the plan, posted to the PR; AWS Budgets alerts | every PR / continuous | a change that quietly adds a NAT gateway per AZ in dev |

**Gaps in the app's own tests, found in this repo.** Worth fixing before any of the above, because they hide failures:
- **Injected latency can't trip the latency SLO.** server.js applies `FAULT_LATENCY_MS` only to `/work`, and the latency SLI measures `/echo` and `/version` (`/work` is left out on purpose: the caller chooses how long it takes). So a latency drill through `/admin/fault`, never moves the latency SLI. A real latency drill has to slow `/echo` indirectly, by saturating the event loop with `/work` calls on the same pods, or by adding latency at Envoy (a fault-injection `BackendTrafficPolicy`), which is the better production drill anyway.
- **The canary's "no data" path.** A canary that gets too little traffic is Inconclusive and pauses, waiting for a human. That's correct (fail closed), but nothing alerts on a Rollout paused for a long time. Add a monitor on a Rollout `Paused` for over 30 minutes.

**Promotion gates, summarised:**
- **dev:** automatic after main's build/sign. Smoke must pass.
- **staging:** promotion PR. Dev smoke passed + dev SLO held 1 h + no monitors + checks green. Patches merge automatically (promoter), features need the owner.
- **prod:** promotion PR. Staging soaked 1 h on that exact digest + staging SLO + synthetics green + latest nightly load green (features) + no critical Inspector finding + owner approval for features. Then canary analysis in prod, post-sync smoke, and synthetics watching.

### 3.10 Release safety: canaries in prod

Locally every release is a rolling update of a plain Deployment named `app`. In production every prod release should be a canary, with **Argo Rollouts** added to the platform.

**Recommend:**
- Add a `Rollout` to the chart, on in prod and staging (so the canary path is itself tested before prod). A native `Rollout` template is clearer for on-call than `workloadRef`, which leaves the Deployment at 0/0.
- **Traffic routing:** Argo Rollouts' Gateway API plugin (Envoy stays, §3.6), with stable and canary Services as the HTTPRoute's two backends.
- **Steps:** 5% (2 min analysis) → 25% → 50% → 100%, plus a **background analysis** throughout. `abortScaleDownDelaySeconds` so a rollback is instant. `dynamicStableScale: true` to avoid doubling capacity. `maxSurge` so the canary pods land in different AZs.
- **AnalysisTemplate with the Datadog provider:** the same two SLIs on the canary only, using a `rollouts-pod-template-hash` tag. Unified Service Tagging gives `version:<tag>`, so query by `version` instead, which is simpler. Datadog metrics arrive with ~1–2 min delay *(unsure on exact latency)*, so set `initialDelay: 2m` and keep the **fail-closed on empty data** design. A Datadog outage then means *Inconclusive → pause*, never a silent pass.
  - Alternative: keep a tiny in-cluster Prometheus (2 h retention) just for analysis. It's faster and has no SaaS dependency, but it's a second metrics system. **Prefer Datadog**, and revisit if the delay makes steps too slow.
- **Low traffic:** if prod's real traffic is low at night, the 5% step will be Inconclusive. Either keep the promoter's trickle running in prod, or schedule promotions within working hours (Argo CD sync windows).
- **If Datadog isn't chosen (§3.8, option C):** the same AnalysisTemplates run against **Amazon Managed Service for Prometheus**. Rollouts' Prometheus provider signs requests with SigV4 through its `authentication.sigv4` block, using a Pod Identity role on the Rollouts controller allowed only `aps:QueryMetrics`. The PromQL is today's SLI recording rules, filtered to the canary's pods. Steps of 10 → 25 → 50 → 100, with an analysis after each, are fine for prod; the 5% first step above only matters at high traffic.
- **Tell Argo CD to ignore the route weights** Rollouts sets: `ignoreDifferences` with jqPathExpression `.spec.rules[].backendRefs[]?.weight`. Without the `?`, a rule with no backends (the `/admin` 403) breaks the expression, Argo CD resets every canary step, and the analysis goes Inconclusive.
- **Rollback paths:** (1) automatic abort by analysis; (2) `kubectl argo rollouts abort` (SSO, restricted to platform on-call); (3) a revert PR of the promotion commit, which is the durable fix, because Git otherwise re-promotes.
- **Notifications:** Argo CD + Rollouts notifications → Slack and Datadog events, so dashboards show "deploy started/aborted" markers (replacing the version-change annotation in the Grafana dashboard).
- **Cross-cluster progression** is the promotion chain itself (§3.5). Within prod, one cluster for now. With a second region, promote region by region with the same gates.
- **Feature flags** (OpenFeature with a flagd or LaunchDarkly backend) are out of scope for a black-box app but worth noting for real services.

### 3.11 Resilience, DR and backups

What's stateful? **Almost nothing.** The app is stateless. Argo CD state is Git plus cluster Secrets (from Terraform). Metrics and logs live in Datadog. That makes DR mainly "rebuild fast and move DNS".

**Recommend:**
- **In-region HA (do now):**
  - Prod across 3 AZs: app topology spread (already in the chart) with `whenUnsatisfiable: DoNotSchedule` on zone, PDB `maxUnavailable: 1` (exists).
  - Envoy 3 replicas + PDB. Kyverno 3 + PDB. CoreDNS scaled with `cluster-proportional-autoscaler` or more replicas, plus a PDB.
  - Karpenter `disruption.budgets`.
  - A NAT gateway per AZ (§3.1).
  - Test with FIS AZ power interruption.
- **Backups:**
  - **Terraform state:** S3 versioning, KMS, replication to the DR region, Object Lock in governance mode for 30 days.
  - **ECR:** cross-region replication of `orders-gateway` to the DR region.
  - **Secrets Manager:** replica secrets in the DR region.
  - **Route 53:** zones are global, but export them nightly anyway (cheap insurance against fat-fingers).
  - **Git:** GitHub is the source of truth, so mirror the repo nightly to CodeCommit or S3 *(an open question whether that's wanted)*.
  - **No Velero** while there are no PVs. Revisit if stateful components arrive. *(AWS Backup has added EKS support. Unsure of its scope and maturity, and probably unnecessary here.)*
- **DR posture, recommend pilot light:**
  - The Terraform for a second region exists and is `plan`ned in CI monthly. ECR and secrets are replicated.
  - Recovery: apply the region's roots, Terraform installs that cluster's Argo CD and root Application (they install the rest), flip the Route 53 failover record.
  - Estimated RTO 60–90 min, RPO ≈ 0 (no data). Active-active multi-region only if the business RTO is minutes (open question).
- **Argo CD loss in one cluster:** workloads keep serving, and only that environment's deploys stop. Reinstall it from Terraform and Git; it adopts what is already running. Runbook plus a quarterly drill.
- **"Rebuild from scratch" drill:** quarterly in staging. Destroy and recreate the cluster from Terraform + GitOps, time it, and keep the number in the README (as the repo did with its 9 min 43 s).

### 3.12 Cost

Rough monthly baseline, eu-west-1, on-demand list prices, **all approximate and unsure**:
| Item | Estimate |
| --- | --- |
| EKS control planes: 3 × ~$73 (dev, staging, prod) | ~$220 |
| Nodes: prod 2 system + ~2–3 apps (m7g.large ~$60 each), staging 2+2, dev 2+1 (Spot); each cluster's Argo CD runs on its system nodes | ~$600–800 |
| NAT: prod 3, others 1 each (~$35 each + $0.048/GB processed) | ~$210 + data |
| ALB: a public and an internal one per environment (~$20 + LCU each) | ~$130 |
| Interface endpoints, prod only (~7 × 3 AZ) | ~$150 |
| WAF: ACL + rules + requests | ~$20–50 |
| Secrets Manager, KMS, Route 53, ECR storage, CloudTrail/Config/GuardDuty/Inspector/Security Hub | ~$100–200 |
| **AWS subtotal** | **~$1.5–1.9k** |
| Datadog (§3.8) | ~$350–600+ |

The table prices the chosen layout: one account, cluster and Argo CD per environment. A shared non-prod cluster would save about $300–400 a month, at the cost of dev and staging isolation; it was considered and not chosen.

**Levers, in order of payoff:**
- Graviton everywhere (already in the sketch). Spot for dev/staging. Karpenter consolidation. **Scale dev to zero nights and weekends** (a Karpenter NodePool limit or kube-downscaler).
- **Datadog:** fewer, bigger nodes; APM only in prod/staging; drop `pod_name` from custom-metric tags; exclusion filters plus Flex/archives for logs; an annual commit once usage is known.
- Compute Savings Plans after 2–3 months of steady usage (prod baseline only).
- VPC endpoints only where they beat NAT data charges.
- Controls:
  - **AWS Budgets per account** with alerts at 80%/100%, plus anomaly detection.
  - Cost allocation tags (`project`, `env`, `component`), enforced by a tag policy in the org. The sketch's `default_tags` already sets `project`/`env`.
  - Datadog Cloud Cost Management or OpenCost for per-namespace cost (Kubecost is fine too). That replaces `./platform budget` in spirit.

### 3.13 Security and compliance

**Recommend (baseline, mostly org-level, cheap to turn on early):**
- **Detection:**
  - CloudTrail organization trail to the log-archive account (S3 with Object Lock, KMS).
  - AWS Config (with conformance packs if a framework applies).
  - **GuardDuty** org-wide with EKS Protection (audit logs) and **Runtime Monitoring** for EKS.
  - **Security Hub** with AWS Foundational Security Best Practices + CIS.
  - IAM Access Analyzer (external and unused access).
  - **Inspector** for ECR and EC2.
  - Delegated admin for all of these in the security account.
- **Cluster:**
  - Private endpoint. Envelope encryption with a CMK.
  - **IMDSv2 with hop limit 1** on nodes, so pods can't reach the node role. Karpenter's EC2NodeClass `metadataOptions`.
  - Pod Security `restricted` on app namespaces (as today, via `managedNamespaceMetadata`).
  - Kyverno all-Enforce, HA, fail-closed for the app namespaces. Turn on background scans.
  - Network policies via the VPC CNI, **adding default-deny egress** for the app namespace (it needs only DNS; the Datadog Agent scrapes it, and it initiates nothing. The canary and tracing don't change that, except that **SSI-injected dd-trace sends traces to the node-local Agent**, so allow egress to the Agent's host port or socket).
  - FQDN egress control for platform namespaces is an open follow-up. Options: Cilium in chaining mode (adds a CNI to operate) or AWS Network Firewall (~$300/month per AZ endpoint *(unsure)*). **Defer.** Start with security groups plus NAT egress logs and GuardDuty.
- **Edge:** WAF as §3.6. TLS 1.2+. ALB access logs. `/metrics` and the probes not exposed.
- **Supply chain:** as §3.4. Plus GitHub hardening:
  - **branch protection on `main`** (`main` has none today), required reviews, and CODEOWNERS for `environments/prod/`, `policies/` and `infra/`.
  - Required status checks. Secret scanning and push protection. Dependabot alerts alongside Renovate.
  - Actions pinned by SHA (already done). Environments with required reviewers for `terraform apply` in prod.
  - Note that the promotion bot's direct push to main (`promote-dev`) then needs a bypass for the GitHub App only.
- **Access:** SSO everywhere. No shared logins (`admin12345` dies). Short sessions for prod. Break-glass with alerts.
- **Compliance:** unknown target (SOC 2? ISO 27001? PCI if "orders" ever means card data?). Security Hub standards and Config conformance packs give evidence cheaply. Open question.

---

### 3.14 Operations: on-call, incidents and day-2 work

The local stack has runbooks and alerts but no people. Production needs the process around them:

- **On-call.** One primary and one secondary rotation for the platform (PagerDuty or Datadog On-Call), with a weekly handover. Only `severity: page` alerts wake someone: today that's the two fast-burn SLO alerts. Everything else is a ticket worked in office hours. Review the page volume monthly. More than ~2 pages a week per rotation means an alert needs fixing, not more on-call.
- **Incidents.** A short written process: declare (any page, or a customer report), one incident commander, a Slack channel per incident (Datadog Incident Management or incident.io), status updates every 30 minutes, then a blameless postmortem within 5 working days for anything that burned more than 10% of the monthly error budget. Postmortem actions become tickets with owners, and runbook fixes land in `runbooks/` in the same week.
- **Error budget policy.** Written down, agreed with the service owner: when the 30-day budget is spent, feature promotions to prod stop (`promotion/PAUSED`, which the promoter already honours) until the budget recovers. Only fixes and patches ship. This is what makes the SLO more than a dashboard.
- **Runbooks.** Keep them in Git next to the alerts, as today, and test them: every quarterly game day (§3.9) works through at least two runbooks as written. A runbook that needed a step not in it gets fixed the same day.
- **Change management.** Every prod change is a merged PR: app promotions, platform values, Terraform. Argo CD sync windows block prod syncs outside working hours except for PRs labelled `hotfix`. Upgrades of platform components (Argo CD, Kyverno, Envoy Gateway, cert-manager, the Datadog Operator) go through Renovate PRs and land in dev, then staging, then prod, a few days apart.
- **Cluster upgrades.** Quarterly, following EKS standard support (§3.2): read the upgrade insights, bump add-ons first, then the control plane, then Karpenter rolls the nodes within its disruption budgets. Major jumps use a blue/green cluster instead.
- **Access reviews.** Quarterly review of Identity Center group membership, Argo CD RBAC and break-glass use. Every break-glass session is alerted and reviewed.
- **Capacity.** A monthly look at the HPA's peak replicas, Karpenter's node count and the SLO latency trend. Raise `maxReplicas` before the HPA sits at its ceiling, not after.
- **Cost review.** Monthly, per account and per namespace (§3.12), with the Datadog bill alongside, since it may be the larger one.
- **Developer experience.** PRs that change the app get a preview: the kind stack in CI is the integration test today, and stays so. Per-PR environments on EKS (an ApplicationSet with the pull-request generator, one namespace per PR, deleted on close) are worth adding once more than one team works on the service. Not before.

## 4. Terraform / IaC structure

Build on `docs/terraform-sketch/`. Its key line holds: **Terraform owns accounts, network, clusters, IAM and anything AWS. Argo CD owns everything inside the clusters.** What changes: the sketch's single root becomes modules + per-account roots, and its `helm_release` for Argo CD + root survives **in every cluster**: Terraform installs Argo CD and the root Application once per cluster, and Argo CD then manages itself and everything else.

```
infra/
  modules/
    org/                 # OUs, SCPs, tag policies, Identity Center permission sets + assignments
    account-baseline/    # per-account: KMS keys, budgets, GitHub OIDC provider, state bucket, default EBS encryption, IMDSv2 default
    network/             # wraps terraform-aws-modules/vpc (as in the sketch) + endpoints + flow logs
    eks-cluster/         # wraps terraform-aws-modules/eks (as in the sketch): system node group, add-ons, access entries,
                         #   Karpenter IAM + SQS interruption queue, Pod Identity associations for LBC/ExternalDNS/ESO/EBS CSI/Datadog,
                         #   ACM cert, WAF ACL, Route 53 zone; outputs a "gitops bridge" map (ARNs, IDs)
    argocd-bootstrap/    # Argo CD HA + SSO via helm_release, and the root Application with this cluster's values
                         #   from eks-cluster's outputs (the sketch's helm_release "argocd"/"root")
    ecr/                 # repos, immutability, scanning config, lifecycle, repo policy (org pull), replication, pull-through rules
    github-ci-roles/     # gha-ecr-push, gha-tf-plan, gha-tf-apply with sub/aud conditions
    dns/                 # apex zone + delegations
    datadog-aws/         # Datadog AWS integration role (cross-account from Datadog), log forwarding if used
  live/
    bootstrap/           # applied once with local state: state buckets + KMS + the tf roles; then migrated to S3
    management/          # org/, Identity Center
    security/            # GuardDuty/Security Hub/Inspector delegated admin, org trail (log-archive)
    shared-services/     # ecr/, github-ci-roles/, dns/ apex
    dev/ staging/ prod/  # each: network/, eks-cluster/, argocd-bootstrap/
    observability/       # datadog provider: SLOs, monitors, dashboards, synthetics, log pipelines/indexes
```

- **State:** one S3 bucket per account (versioned, KMS, S3 native lockfile as in the sketch's `use_lockfile = true`), key `<root>/terraform.tfstate`. CI assumes the target account's plan/apply role, so no cross-account state access is needed. Separate roots for `network` and `eks-cluster` within an env, so a cluster rebuild doesn't touch the VPC. Small roots keep plans fast and blast radius small.
- **Locking:** Terraform 1.10+ locks state with a lockfile in the S3 bucket itself (`use_lockfile = true`), so the older S3 + DynamoDB lock table isn't needed. The DynamoDB table also works, but the lockfile is one less resource.
- **Which repo:** the Terraform can live in **its own repo** (`orders-gateway-infra`), with its own reviewers and CODEOWNERS, so a platform-config PR can never touch IAM by accident. The layout below works as a separate repo or as `infra/` here. **Recommend a separate repo** (see the three repositories in §3.5).
- **Tooling:** plain Terraform (or OpenTofu; open question) with one `env.tfvars` per root. Terragrunt helps with DRY backends and dependency ordering across ~15 roots. **Recommend starting without it** and adding it if the copy-paste hurts.
- **Pin providers and modules.** Renovate already manages pins. Add the `terraform` manager.
- **CI:** `.github/workflows/infra.yml`. On PR: fmt, validate, tflint, checkov/trivy config, and `plan` for changed roots, posted as a PR comment. On main: `apply` per root in dependency order. Prod roots wait on a GitHub Environment approval. **Nightly drift detection** (`plan -detailed-exitcode`) opens an issue on drift (the same pattern as `rescan.yml`'s tracking issue).
- **Handover to Argo CD (the GitOps bridge):**
  1. `eks-cluster` creates the cluster, the system node group and the Pod Identity associations, plus the AWS resources the in-cluster controllers will need (roles, ACM cert, WAF ACL, zone).
  2. `argocd-bootstrap` installs Argo CD with `helm_release` and creates the root Application, passing those outputs as Helm values: `{env: prod, aws: {lbcRole: ..., certArn: ..., wafArn: ..., zone: ..., clusterName: ...}}`.
  3. The root renders `gitops/apps` with those values, and the existing waves install Karpenter, LBC, ExternalDNS, ESO, Kyverno, Envoy Gateway, the Datadog Operator and finally the app. Argo CD then manages its own release through its `argocd` Application, so Terraform's `helm_release` is only the first install (`lifecycle { ignore_changes = all }`).
  4. Terraform applies nothing else to Kubernetes, so there's one owner per object, the property the sketch's README insists on.
- **Not in Terraform:** anything with a Kubernetes API, Helm values of platform components, the app's environments. **In Terraform even though it's "observability":** Datadog monitors, SLOs and dashboards (§3.8).

---

## 5. Phased migration plan

**Phase 0: choices and foundations (1–2 weeks)**
- Answer the open questions below, especially region, domain, IdP and budget.
- `live/bootstrap`, the Organization, SCPs, Identity Center, the security/log-archive baseline (CloudTrail, GuardDuty, Security Hub, Config), budgets.
- GitHub: branch protection on main, a GitHub App for automation, individual identities.

**Phase 1: images (≈1 week)**
- ECR + pull-through cache + GitHub OIDC push role.
- `cd-app.yml` dual-pushes GHCR and ECR, signing both. The demo tags move to a separate repo.
- Kyverno policies accept both registries (in the local stack too, so CI keeps testing the policies).

**Phase 2: the dev account and cluster (2–3 weeks)**
- The dev network and cluster, with its own Argo CD (HA + SSO).
- **Repo refactor:** cluster values in `gitops/apps` (`env`, `aws`), so each cluster's root turns on only its own environment's Application; the EKS values layer; ESO, LBC, ExternalDNS and Karpenter Applications.
- **Keep the kind path working.** The local root keeps all three environments in one cluster, as `orders-gateway-dev`, `-staging` and `-prod`, so the Compose stack and CI's cluster job still test the same templates.
- The Datadog Operator in dev. Run it **in parallel with** kube-prometheus-stack in dev for a couple of weeks to check that the Datadog SLO numbers match the PromQL recording rules.

**Phase 3: observability as code (1–2 weeks, overlaps phase 2)**
- The `observability` root: the two SLOs × env, burn-rate monitors, platform monitors, ports of the `orders-gateway` and `platform-overview` dashboards, synthetics.
- PagerDuty/Slack routing. Runbooks updated with Datadog queries.
- Promoter gates switched to the Datadog APIs.

**Phase 4: staging + test series (2 weeks)**
- Staging: its own account, cluster and Argo CD, from the same modules. The canary on in staging.
- PostSync smoke hooks, the k6 Operator nightly load, the weekly soak, the API tests in PR CI, the alert fire drill, the first FIS game day.

**Phase 5: prod (2 weeks + soak)**
- The prod account, NAT per AZ, endpoints, the ALB with WAF and ACM, the canary with Datadog analysis, Kyverno fail-closed, GuardDuty runtime monitoring.
- A prod game day before traffic. DNS cut-over (if there's existing traffic, weighted Route 53 records to ramp up).

**Phase 6: can wait**
- DR-region pilot light and its drill, Savings Plans, Argo CD Agent if one UI across the three Argo CDs is wanted, FQDN egress control (Cilium/Network Firewall).
- Kargo, a multi-region active-active setup, AWS Private CA, Shield Advanced, Velero/AWS Backup (only if state appears).

**Remove after prod is live:** kube-prometheus-stack, Loki, Alloy, Grafana, `alert-receiver` and Sealed Secrets from the EKS layer. **Keep them in the local kind stack**: the "cluster in a box" remains the offline teaching and CI environment, and the README should say which layer is which.

---

## 6. Open questions for the owner

**Decided:** one account, one EKS cluster and one Argo CD per environment (dev, staging, prod). No hub, no shared non-prod cluster.

1. **Region(s) and data residency:** eu-west-1 as in the sketch? Is a DR region required, and what RTO/RPO?
2. **Real traffic and users?** Expected request rate decides node counts, whether prod needs the trickle for canaries, and whether Datadog's cost is justified.
3. **Budget ceiling**, and is there an existing Datadog contract and site (US1 vs EU1)? An existing PagerDuty, or Datadog On-Call?
4. **Datadog all-in vs AWS-managed Prometheus/Grafana:** OK with rewriting `alerts/` and `dashboards/` as Datadog Terraform, and losing the promtool unit tests in favour of fire drills?
5. **IdP** for Identity Center, Argo CD and Datadog SSO (Okta, Entra, Google)?
6. **Domain name** for the apex zone, and are the per-env subdomains OK?
7. **Public Sigstore OK** (keyless signatures in the public Rekor log naming the repo), or switch to cosign with a KMS key?
8. **Compliance target** (SOC 2, ISO 27001, PCI)? It changes Config packs, log retention and access reviews.
9. **Who approves prod promotions** once every person and bot has its own GitHub identity? Does the patch promoter keep auto-merging prod patches?
10. **Kyverno fail-closed in prod:** accept that a full Kyverno outage blocks new app pods (including rollbacks), relying on 3 replicas + PDB? Or keep `Ignore` with background re-scans as the safety net? Recommend **Fail**.
11. **Terraform or OpenTofu**, and Terragrunt or plain roots?
12. Should **prod's public edge stay this strict** (only `/work`, `/echo`, `/version`), when the local edge forwards everything the app serves?
