# 0031: Which Applications delete their resources when they go

**Status:** Accepted, 2026-11-25

## Context

Renaming the environments (#77) removed the `orders-dev`, `orders-staging` and `orders-prod` Applications from Git. The root app-of-apps pruned them, but without Argo CD's `resources-finalizer` an Application is deleted *alone*: its Deployments, Services and HTTPRoutes stayed. On a long-running cluster those orphans kept serving, and because Gateway API gives a hostname to the *oldest* route, the orphaned routes for `orders.localtest.me` won over the new ones. A fresh install isn't affected; any later rename or removal would be.

## Choice

`finalizers: [resources-finalizer.argocd.argoproj.io]` on the Applications whose resources are our own manifests: `dev`, `staging`, `prod`, `promoter`, `platform-alerts`, `platform-gateway`, `network-policies` and `kyverno-policies`. Pruning or deleting one of them now deletes what it created.

**Not** on:
- `argocd` (deleting that Application must never delete Argo CD),
- the CRD Applications (`gateway-crds`, `prometheus-operator-crds`) and the controller charts that ship CRDs (cert-manager, Kyverno, Envoy Gateway, kube-prometheus-stack, Argo Rollouts, Sealed Secrets, Trivy Operator, and Loki, Alloy and metrics-server with them). A cascading delete there removes a CRD and with it every object of that kind in the cluster. Removing a controller should be a deliberate cleanup, not a side effect of a rename.

## Consequences

- A cluster that went through #77 before this keeps its orphans (namespaces `orders-dev`, `orders-staging`, `orders-prod`) until they're deleted by hand or the cluster is rebuilt.
- The demo copy (`scripts/demo.sh`) already sets the finalizer for the same reason.
