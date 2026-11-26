# system/registry

The in-stack registry: CNCF Distribution (`registry:3`), one pod with a 5 GiB volume. It holds what `./pipeline ci <app> --version V` publishes, and the cluster runs only what's in it.

| What | Where |
| --- | --- |
| Images | `localhost:30500/<app>:<version>` (and dev-only builds, `<app>:local-<time>`). Each node's containerd pulls through the registry's NodePort 30500 on its own localhost, over plain HTTP, which containerd allows for localhost: no registry config on the nodes. |
| Charts | `oci://registry.registry.svc.cluster.local:5000/charts/<app>`, version = the release. Argo CD reads them (repository `registry` in `system/argocd/values.yaml`). |
| Pushes | `scripts/registry.sh`, through `kubectl port-forward`. A published version is never overwritten: `./pipeline` checks first, and deletes are off. |

Applied by `scripts/registry.sh install` (from `./platform up`) before Argo CD exists, like the Git server. `scripts/registry.sh seed` then builds and publishes every version the env files pin that a fresh cluster's registry lacks: a bootstrap build from the checkout, untested, not a release.

What's protected, and what isn't:

- Images are pinned by digest: `./pipeline cd` writes `image.digest` into the env file, so a pod runs exactly the image that was deployed, even if the tag were pushed again.
- Charts are pulled by version tag (Argo CD has no digest pin for Helm OCI charts). `./pipeline` never re-publishes a version and deletes are off, but the registry has no login: anything in the cluster, or anyone with `kubectl port-forward`, could push over a tag. Fine for a local practice cluster; production uses a registry with access control and immutable tags.
- The versions a fresh cluster builds at `./platform up` (0.1.0) run by tag until their first `./pipeline cd`.

In production the registry is ECR (or GHCR) and CI publishes: see `docs/production.md`.
