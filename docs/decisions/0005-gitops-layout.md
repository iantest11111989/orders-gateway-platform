# 0005: GitOps layout, app-of-apps as a Helm chart, sync waves

**Status:** Accepted, 2026-11-21

## Context

Argo CD must manage everything after bootstrap, including itself. Reviewers run the stack from their own fork or a branch (`REPO_URL=… REVISION=… ./platform up`), so no file should hard-code where Git lives. Two agents add components in parallel and need one convention.

## Options

1. A plain directory of Application manifests. Simple, but every child hard-codes `repoURL`/`targetRevision`, so a fork or branch silently deploys upstream `main`.
2. An ApplicationSet. Powerful, but harder to read for people learning Argo CD.
3. App-of-apps rendered as a small **Helm chart**. The root passes the repo and revision as values, and each child template uses them.

## Choice

Option 3.

```
gitops/
  root.yaml                    root Application, applied once by ./platform up
  apps/                        Helm chart "platform-apps" (the app-of-apps)
    values.yaml                repo.url, repo.revision (overridden by up)
    templates/<component>.yaml one Argo Application per component
  values/<component>.yaml      Helm values for that component's chart
  manifests/<component>/       plain YAML belonging to a component (rare)
```

- **Child Applications** use multi-source:
  - The upstream chart at a pinned `targetRevision`.
  - This repo as `ref: values` with `repoURL: {{ .Values.repo.url }}` and `targetRevision: {{ .Values.repo.revision }}`, plus `valueFiles: [$values/gitops/values/<component>.yaml]`.
  - Extra manifests from this repo come in as a further source with the same repo values.
- **Sync waves** (`argocd.argoproj.io/sync-wave` on the Application):

  | Wave | Contents |
  | --- | --- |
  | -10 | CRD-only Applications (Prometheus Operator, Gateway API, cert-manager, Rollouts CRDs) |
  | 0 | Argo CD itself |
  | 10 | Controllers (cert-manager, Envoy Gateway, Sealed Secrets, Kyverno, metrics-server) |
  | 20 | Observability |
  | 30 | Policies |
  | 40 | Apps (orders-gateway dev, staging, prod) |

  The gaps leave room for later additions.
- **Every Application** gets `syncPolicy.automated` (prune + selfHeal), `ServerSideApply=true` for CRD-heavy charts, and the label `app.kubernetes.io/part-of: orders-gateway-platform`.
- **Waves only work with an Application health check.** Argo CD removed the built-in one in 1.8, so `gitops/values/argocd.yaml` restores it (`resource.customizations.health.argoproj.io_Application`). Without it, every child counts as Healthy the moment it exists and later waves don't wait.
- **CRDs come first, in their own Applications** (wave -10), so charts in later waves, including Argo CD's own ServiceMonitors, never render custom resources before their CRDs exist. Charts that also ship those CRDs run with their CRD install turned off. Applications whose templates may reference not-yet-installed CRDs also set `SkipDryRunOnMissingResource=true`.
- **No resources-finalizer** on the `argocd` Application. Deleting it must never delete Argo CD.
- **Bootstrap:** `scripts/argocd-bootstrap.sh` installs Argo CD once with Helm, using the same chart version and `gitops/values/argocd.yaml` as `gitops/apps/templates/argocd.yaml`. It then applies `root.yaml` with the repo and revision set, and waits until every Application is Synced and Healthy. From then on Argo CD manages itself from Git, and re-runs skip the Helm step.
- **Trimmed Argo CD:** no Dex, no notifications controller, no Redis HA, single replicas, and resource requests set. Metrics are enabled, and the ServiceMonitors are switched on in the observability PR.

## Consequences

- A fork or branch deploys entirely from itself. CI uses this to test each PR's own branch.
- Component authors write Helm templates, not plain YAML. In practice that means two `{{ .Values.repo.* }}` lines per Application.
- The bootstrap Helm values and the self-managed values are the same file, so they can't drift. The chart version lives in one place (the Application), and the bootstrap reads it from there.
