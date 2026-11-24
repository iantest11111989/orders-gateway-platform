# 0010: Renovate keeps every pin current

**Status:** Accepted, 2026-11-24

## Context

The brief (section 10) asks Renovate to keep every pin current (Go modules, base images, Helm charts, GitHub Actions by SHA, toolbox tools, the kind node image), run daily, auto-merge patch updates once checks pass, and leave minor and major updates for the owner. The automated dev → staging → prod patch promotion with soak gates comes in its own PR.

## Choices

- **The Renovate GitHub App** (Mend, free), chosen by the owner on 2026-11-24. It needs no token or workflow in this repo, and its PRs trigger CI like any other PR. A self-hosted Renovate in Actions would need a PAT or GitHub App key stored as a secret, because PRs opened with the default `GITHUB_TOKEN` don't trigger workflows.
- **Config in `renovate.json5`**, so each rule can carry a comment.
- **Schedule:** before 6 am New York time, daily; at most 5 open PRs.
- **Auto-merge:** patch, digest and pin updates only. `platformAutomerge: false`: Renovate merges itself after it has seen every check pass. GitHub's native auto-merge would merge at once, since `main` has no required checks.
- **Owner approval:** minor and major updates are not auto-merged and carry a `needs-owner-approval` label. A grouped PR auto-merges only if every update in it may.
- **Pins Renovate can't parse on its own** get custom regex managers:
  - Helm charts in `gitops/apps/templates/` (Helm templates, so the built-in `argocd` manager can't read them): `repoURL` + `chart` + `targetRevision`, from HTTPS chart repos and from `docker.io/envoyproxy` (OCI). OCI charts don't get a digest added, because Argo CD's `targetRevision` takes a plain version.
  - `toolbox/versions.env`, through the `# renovate:` comment above each pin.
  - The kind node image in `cluster/kind.yaml` (tag + digest).
- **Groups:** kube-prometheus-stack with prometheus-operator-crds (same operator version); Envoy Gateway's CRD and controller charts; the Argo CD chart with the `argocd` CLI; Loki with Alloy; the kind node image with kind (never auto-merged, since a node image must match a kind release); GitHub Actions.
- **Not Renovate's job:** the orders-gateway image tag in `charts/` and `environments/`. CI bumps it on merge and promotion PRs move it (decision 0009).

## Consequences

- Version comments after a pin (for example `# Loki 3.6.20` next to `targetRevision: 7.7.0`) aren't updated by Renovate. Reviewers fix them in the update PR.
- Grouping keeps related charts in one PR but doesn't force matching versions. The prometheus-operator group still needs a reviewer to check that both charts ship the same operator.
- Until the app is installed on the repo, nothing runs. Once installed, Renovate first opens an onboarding PR, then a Dependency Dashboard issue listing every update.

## Tests

- `renovate-config-validator --strict` (Renovate 44.261.0): valid.
- A local lookup-only dry run (`--platform=local --dry-run=lookup`) found every pin above: 9 charts, 11 toolbox tools, 3 kind node images, all actions by SHA, both Dockerfiles and `go.mod`. It would open six branches: `pin-dependencies`, a distroless digest, cosign v3.1.5 (patch, auto-merge), and three that wait for the owner (`argo-cd`, with chart 10.19.0 and CLI v3.6.3; `prometheus-operator`, with kube-prometheus-stack 93.10.0; and Ubuntu 26.04 runners).
