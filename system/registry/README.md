# system/registry

The in-stack registry: CNCF Distribution (`registry:3`), one pod with a 5 GiB volume. It holds what `./pipeline ci <app> --version V` publishes, and the cluster runs only what's in it.

| What | Where |
| --- | --- |
| Images | `localhost:30500/<app>:<version>` (and dev-only builds, `<app>:local-<time>`). Each node's containerd pulls through the registry's NodePort 30500 on its own localhost, over plain HTTP, which containerd allows for localhost: no registry config on the nodes. |
| Charts | `oci://registry.registry.svc.cluster.local:5000/charts/<app>`, version = the release. Argo CD reads them (repository `registry` in `system/argocd/values.yaml`). |
| Pushes | `scripts/registry.sh`, through `kubectl port-forward`. A published version is never overwritten: `./pipeline` checks first, and deletes are off. |

Applied by `scripts/registry.sh install` (from `./platform up`) before Argo CD exists, like the Git server. `scripts/registry.sh seed` then builds and publishes every version the env files pin that a fresh cluster's registry lacks: a bootstrap build from the checkout, untested, not a release.

In production the registry is ECR (or GHCR) and CI publishes: see `docs/ci-cd-in-production.md`.
