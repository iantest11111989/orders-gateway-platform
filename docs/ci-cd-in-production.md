# CI/CD in production

This repo runs all of its CI/CD on your machine. `./pipeline ci` tests, builds, scans and (with `--chart`) releases the chart. `./pipeline cd` deploys by changing `cd/<app>/<env>.yaml`, and Argo CD syncs that change from the Git server inside the cluster. GitHub only runs checks on pull requests. This page describes how a production team would run the same pipeline in CI, and why this repo doesn't. Nothing here is built locally: the repo produces no versioned packages, and this page only describes them.

The AWS side (accounts, ECR, IAM, one Argo CD per cluster) is in [`production-on-aws.md`](production-on-aws.md), §3.4 and §3.5. This page covers the pipeline itself.

## 1. Choosing a CI provider

| Provider | For | Against | Verdict |
| --- | --- | --- | --- |
| **GitHub Actions** | The code is already on GitHub. OIDC to AWS and keyless cosign signing work without stored secrets. Environments with required reviewers serve as promotion gates. Big marketplace; actions can be pinned by SHA. | Hosted runners are small (4 CPUs) and per-minute billed. Marketplace actions are a supply-chain risk unless pinned. Complex fan-out gets verbose. | **Recommended.** It's where the repo, reviews and identities already are. Use self-hosted or larger runners for the E2E. |
| GitLab CI | Strong pipelines, built-in registry and environments | Means moving the repo or mirroring it | Only if the organisation is on GitLab |
| Buildkite | Your own runners, fast, good for monorepos with many apps | Another vendor and runner fleet to run | Worth it at many apps, or for heavy builds |
| CircleCI | Fast, good caching | Another vendor; OIDC and signing need more setup | No advantage over Actions here |
| Jenkins | Runs anywhere, fully controllable | Plugin upkeep, security patching, no keyless OIDC by default | No |
| AWS CodeBuild / CodePipeline | Native IAM, runs in the VPC | Weak pull request UX; reviews still happen in GitHub | Only as a runner for steps that must run inside AWS |
| Tekton / Argo Workflows | Kubernetes-native, close to Argo CD | You run the CI system on the clusters it deploys to | No: keep CI outside the clusters |

## 2. The pipeline stages

The stages are the ones `./pipeline ci` and [`ci-app.yml`](../.github/workflows/ci-app.yml) run today. Production adds pushing to a registry and signing for real.

| Stage | Locally (`./pipeline ci`) | On a pull request (`ci-app.yml`, today) | On main (production) |
| --- | --- | --- | --- |
| **Lint** | `npm run lint` | `npm run lint`, hadolint (Dockerfile), plus shellcheck and actionlint in `platform.yml` | same as the pull request |
| **Test** | `npm test` in the Dockerfile's Node image | the same, then a smoke test of the built image (non-root, read-only, endpoints, SIGTERM drain) and a 60 s k6 gate held to the SLOs | same as the pull request |
| **Build** | `docker build`, loaded into kind as `localhost/<app>:<tag>` | both architectures (amd64 and arm64), pushed nowhere | both architectures, pushed by digest |
| **Scan** | Trivy, the version CI pins; fails on a HIGH or CRITICAL with a fix | same | same, on the pushed digest. The registry rescans continuously (ECR + Inspector) for CVEs published later |
| **Sign** | not signed: Kyverno admits `localhost/` images only locally | a rehearsal against a throwaway local registry | cosign keyless (OIDC identity = this workflow on `refs/heads/main`), an SBOM attached, then `cosign verify` |
| **Publish** | nothing | nothing | the image to the registry, and the chart as an OCI package when its version went up (§3) |
| **Deploy** | `./pipeline cd <app> <env>` commits to the in-stack Git server | nothing | dev: a commit to `cd/<app>/dev.yaml`. staging and prod: a promotion PR (§4) |

Rules that stay the same everywhere:
- **Pull requests get no secrets and a read-only token.** Only main publishes or signs. Every job declares least-privilege permissions.
- **Pin everything** by digest or commit SHA (actions, Trivy, the Node image), and let Renovate update the pins.
- **Build once, promote the digest.** staging and prod run the same image that dev ran, by digest. Nothing is rebuilt for an environment.
- **The deploy step is a Git change, not a `kubectl` command.** CI never holds cluster credentials. Argo CD in each cluster pulls.

## 3. How the image and the chart ship together

Each environment's file pins both things that run there:

```yaml
# cd/orders-gateway/prod.yaml
chartVersion: 0.3.0          # which chart
image:
  tag: sha-9ab553b08d9f      # which image (tag for people, digest for the cluster)
  digest: sha256:4a3e...
```

- **The image** is built and pushed on every merge to main that changes `apps/<app>/`. Its tag is the commit (`sha-<12 hex>`) and its digest is immutable.
- **The chart** is published only when `helm/<app>/Chart.yaml`'s `version` goes up: `helm package`, `helm push` to an OCI registry (`oci://<registry>/charts/<app>`), signed with cosign. A version can't be overwritten (immutable tags in the registry, and CI refuses an existing version). Locally, a copy in `releases/<app>/<version>/` plays this role, and `CI · chart versions` enforces the same rules: bump on change, never edit a release.
- **The Argo CD Application** for staging or prod takes the chart from the registry at `chartVersion` and the values from Git (`cd/<app>/values.yaml` + `<env>.yaml`).
- **They move independently or together.** An app change bumps only `image`. A chart change (a new probe, a PDB setting) bumps only `chartVersion`. A change that needs both (say, a new port in the app and in the Service) bumps both in the same promotion PR, so they can't arrive out of order. dev runs the chart from `helm/<app>/` as it is, so a chart change is tested in dev before it's released.
- **Compatibility:** the chart should keep working with the image before it (and the other way round) for one version, so either can be rolled back alone.

## 4. Promotion: a pull request per environment file

```mermaid
flowchart LR
  merge["merge to main"] --> ci["CI: lint, test, build,<br/>scan, sign, publish"]
  ci -->|"commit image to cd/app/dev.yaml"| dev(["dev"])
  ci -->|"open PR: promote/staging"| st["PR: cd/app/staging.yaml"]
  st -->|"checks green, reviewed, merged"| stg(["staging"])
  stg -->|"soaked; open PR: promote/prod"| pr["PR: cd/app/prod.yaml"]
  pr -->|"approved by the owner"| prod(["prod"])
```

- **dev** follows main: CI commits the new image to `cd/<app>/dev.yaml` right after publishing. That's the only direct push to main, made by a GitHub App with a narrow branch-protection bypass.
- **staging and prod** move by pull request. CI opens or updates `promote/staging` with the new image (and `chartVersion`, if the chart was released). The PR changes only that environment's file, so its diff is the release. Merging it is the deploy.
- **Gates** run as checks on the promotion PR: dev healthy and within its SLO for a soak period, no firing alerts, an E2E run against the change, then human approval for prod (a GitHub environment with required reviewers). `production-on-aws.md` §3.5 adds a patch promoter that auto-merges patch-only changes once they've soaked.
- **Rollback** is a revert PR of the promotion commit, back to the previous digest and chart version. Argo CD syncs it like any other change. The same thing locally is `./pipeline rollback <app> <env>`.
- **Many apps:** each app has its own `cd/<app>/` files and its own promotion PRs, so apps release on their own schedules. A pipeline triggered by `apps/<app>/**` (a matrix over changed apps) keeps one workflow for all of them.

## 5. Why this repo keeps CI/CD local

The repo has to do two things: start the whole Kubernetes stack from one checkout on any machine, and show a real delivery pipeline. In GitHub, the two pull against each other:

- **A GitHub pipeline needs the cluster to follow GitHub.** Then a fresh clone can't deploy its own changes without pushing to GitHub, and a fork or an offline machine can't run the stack at all. The local stack follows its own Git server, which holds exactly the checkout it was started from.
- **Two modes means two things to test.** The repo used to have a "GitHub mode", where CI pushed images to GHCR, committed to dev and opened promotion PRs. Every change had to work in both modes, and the promotion PRs depended on GitHub tokens, branch protection and a published registry.
- **Packages need a registry.** Publishing images and charts per app means credentials, retention and signing identities, none of which a local demo can reproduce faithfully. Pretending to would be worse than describing it.
- **What stays on GitHub is what any clone can reproduce:** lint, manifest validation, policy tests, the app's pull request checks, security scans and the fresh-install E2E. None of them deploy or publish, apart from the toolbox image the scripts run in.

So the local pipeline keeps the shape of production (stages, Git-driven deploys, immutable releases, rollback by Git change), and this page and `ci-app.yml` show what moves to CI in a real setup.
