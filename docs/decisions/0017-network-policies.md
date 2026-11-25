# 0017: NetworkPolicies for the platform namespaces

**Status:** Accepted, 2026-11-24

## Context

The brief (section 9) asks for NetworkPolicies, so that a compromised pod can't reach everything else. The app namespaces already have one from the orders-gateway chart: ingress only from Envoy Gateway and monitoring on the app port, and egress only to DNS. Argo CD's chart ships its own. The other platform namespaces had none: any pod could reach Grafana, Prometheus, Loki, the Kyverno and cert-manager webhooks, and the Rollouts dashboard.

kind's own CNI, kindnet, enforces NetworkPolicy (kind v0.24 and later). That was checked on ogp: under a deny-all, a pod on another node gets no answer.

## Choices

- **One Application, `network-policies` (wave 30), with plain manifests in `gitops/manifests/network-policies/`, one file per namespace.** It covers `monitoring`, `logging`, `kyverno`, `cert-manager`, `argo-rollouts` and `envoy-gateway-system`.
- **Ingress only.** Each namespace gets `default-deny-ingress`, `allow-same-namespace` and `allow-from-nodes`, plus one policy per cross-namespace flow, with its ports:

  | To | From | Ports | Why |
  | --- | --- | --- | --- |
  | monitoring (Grafana, Prometheus, Alertmanager) | envoy-gateway-system | 3000, 9090, 9093 | the platform HTTPRoutes |
  | monitoring (Prometheus) | argo-rollouts | 9090 | canary analysis queries |
  | logging (Loki, Alloy) | monitoring | 3100, 12345 | Grafana queries Loki; Prometheus scrapes both |
  | kyverno | monitoring | 8000 | metrics |
  | cert-manager | monitoring | 9402 | metrics |
  | argo-rollouts | monitoring | 8090 | metrics |
  | argo-rollouts (dashboard) | envoy-gateway-system | 3100 | the dashboard HTTPRoute |
  | envoy-gateway-system | monitoring | 19001 | metrics |
  | envoy-gateway-system (proxies) | anywhere | 10080, 10443 | the public HTTP/HTTPS entry point |

  Egress stays open for now. The platform components need the API server, image registries, Sigstore and the Trivy DB, and kind has no stable IPs or FQDN policy to name those with. Locking egress down is a follow-up for a CNI that supports FQDN rules.
- **"The nodes" is an ipBlock: `0.0.0.0/0` except the pod range `10.244.0.0/16`.** On kindnet, a deny-all also drops traffic from the control-plane node to pods on other nodes. That's where the API server runs, so it breaks admission webhooks (Kyverno, cert-manager) and the API server's service proxy (`./platform verify`, `kubectl get --raw …/proxy`). Same-node kubelet probes still work. The ipBlock lets nodes in and keeps other pods out. `cluster/kind.yaml` sets `podSubnet: 10.244.0.0/16` explicitly, so the `except` can't silently stop matching pods.
- **Webhook ports aren't opened to everyone.** The API server reaches them as "a node". Only the Envoy proxies' listeners take traffic from any source, because they're the entry point.

## kind limitation, and what a real CNI would do instead

The node ipBlock is the coarsest thing that works on kindnet: it trusts anything that isn't a pod. With Cilium, the same rules would use `fromEntities: [kube-apiserver]` for the webhooks and the service proxy, and `fromEntities: [host]` for the kubelet. Calico has equivalent host-endpoint and global network sets. Both also support egress by FQDN, such as `toFQDNs: ghcr.io`, which would let egress be locked down too.

## Tests (on ogp, policies applied by hand, then removed)

- `./platform verify` (#27) passed: Apps, Prometheus targets (50, none down), Loki logs from all namespaces, HTTPS, and Kyverno flagging a `:latest` dry run.
- Both webhooks answered dry runs: a cert-manager `Certificate`, and a `:latest` pod that Kyverno flagged.
- A pod in `default` got no answer from Grafana, Loki, Kyverno's metrics or the dev app.
- A pod in `argo-rollouts` reached Prometheus (200) and got no answer from Grafana.
- Target count without the policies: 50, the same as with them.
