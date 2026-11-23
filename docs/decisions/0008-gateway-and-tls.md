# 0008: HTTPS entry point: Envoy Gateway, cert-manager and a demo CA

**Status:** Accepted, 2026-11-23

## Context

The brief (sections 4 and 7) fixes the building blocks: Gateway API with Envoy Gateway (not ingress-nginx, which is retired), cert-manager with a local demo CA, `*.localtest.me` hostnames, Envoy terminating HTTPS, HTTP redirected to HTTPS, and `./platform up` explaining how to trust the CA. The kind cluster already maps host `127.0.0.1:80/443` to NodePorts `30080/30443` on the control plane (decision 0004). Later PRs need the Gateway API CRDs too (the app's HTTPRoutes, Argo Rollouts' Gateway API plugin).

## Choices

**Applications** (waves from decision 0005):

| Application | Wave | Namespace | Pod Security enforce |
| --- | --- | --- | --- |
| `gateway-crds` (chart `gateway-crds-helm` 1.10.0) | -10 | (cluster-scoped) | n/a |
| `cert-manager` (chart v1.21.3) | 10 | `cert-manager` | restricted |
| `envoy-gateway` (chart `gateway-helm` 1.10.0) | 10 | `envoy-gateway-system` | restricted |
| `platform-gateway` (`gitops/manifests/gateway/`) | 15 | several | n/a |

- **CRDs in their own Application**, like the Prometheus Operator CRDs in 0007: Gateway API (experimental channel, a superset of standard) and Envoy Gateway's own CRDs install at wave -10, and `envoy-gateway` runs with `crds.enabled: false`. cert-manager keeps its CRDs in its chart (`crds.enabled`, `crds.keep`): nothing outside it uses them before wave 15.
- **Both Envoy charts come from Docker Hub's OCI registry.** Argo CD 3 pulls OCI Helm charts with `repoURL: docker.io/envoyproxy` and `chart: <name>`, no repository Secret needed for a public registry (verified live).
- **One shared Gateway** (`envoy-gateway-system/platform`) with two listeners. `http` (port 80) only accepts the redirect route from its own namespace, which sends a 301 to HTTPS. `https` (port 443, hostname `*.localtest.me`) terminates TLS and accepts HTTPRoutes from every namespace. Each app brings its own HTTPRoute.
- **Demo CA made in the cluster**: a self-signed ClusterIssuer signs one CA certificate, and the `ogp-demo-ca` ClusterIssuer signs everything else. A new CA per cluster means no private key in Git and nothing to rotate; the cost is that a reviewer re-trusts it after `./platform down && up`. `./platform urls` exports the CA certificate to `.build/ogp-demo-ca.crt` and prints the trust commands, or the reviewer can accept the browser warning.
- **One certificate** for `localtest.me`, `*.localtest.me`, `*.dev.localtest.me` and `*.staging.localtest.me`. A certificate wildcard covers one DNS label only, so the per-environment names need their own entries. (A Gateway API listener wildcard matches one or more labels, so the single `*.localtest.me` listener serves them all.) ECDSA P-256, 90 days, renewed 30 days early, like Let's Encrypt.
- **Envoy proxy** (`EnvoyProxy` `platform`, referenced by the `envoy` GatewayClass): one replica, NodePort Service with node ports pinned to 30080/30443, and `externalTrafficPolicy: Cluster`. The default `Local` would drop traffic, because it enters through the control plane node while the proxy runs on a worker. Access logs are JSON on stdout for Loki. Pods run restricted (non-root, RuntimeDefault seccomp).
- **Routes for the platform UIs**: `argocd`, `grafana`, `prometheus` and `alertmanager.localtest.me`. Argo CD already serves plain HTTP behind the gateway (`server.insecure` in `gitops/values/argocd.yaml`). Prometheus and Alertmanager have no login, which is acceptable only because the kind port mapping binds to `127.0.0.1`.
- **Metrics**: PodMonitors for the Envoy Gateway controller and the Envoy proxies (port 19001), and cert-manager's ServiceMonitor.

**Tests:** `scripts/check-https.sh` checks every hostname over HTTPS against the demo CA and checks the HTTP redirect. CI runs it after `./platform up`.

## Resource impact

Requests: 0.12 CPU and 312 Mi in total (cert-manager controller, webhook and cainjector 30m/120Mi; Envoy Gateway 25m/96Mi; Envoy proxy 50m/64Mi plus its shutdown manager 10m/32Mi). Memory limits: 896 Mi, one on every container. Measured on the live cluster.

## Consequences

- **Hosts that already use ports 80/443** can't reach the gateway, because kind's port mapping fails to bind or (with Colima) the VM's ports aren't forwarded. Example: the Mac mini runs another web server on 80/443, so there the URLs work from inside the Colima VM and `./platform shell`, but not from the Mac's browser. A follow-up will make the host ports configurable (for example `HTTPS_PORT=8443 ./platform up`).
- Production would use a public CA (Let's Encrypt via ACME DNS-01) or the company PKI, real DNS, a cloud load balancer instead of NodePorts, two or more proxy replicas, and SSO in front of Prometheus and Alertmanager (README, production differences).
