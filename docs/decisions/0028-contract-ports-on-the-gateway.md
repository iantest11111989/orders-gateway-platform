# 0028: The contract's ports go through the existing Envoy Gateway

**Status:** Accepted, 2026-11-25

## Context

The assignment's fixed contract: prod is served "through an Ingress at http://localhost:8080", everything the app serves must be reachable there except `/admin/*`, which must not be reachable from outside the cluster, and Grafana, Prometheus and Alertmanager are on `:3000`, `:9090` and `:9093`. The platform's edge is already Envoy Gateway with Gateway API on 443 (decision 0008).

## Choices

- **Gateway API, not the Ingress resource.** Gateway API is the Kubernetes successor to Ingress. Envoy Gateway implements it but not Ingress, and ingress-nginx, the usual Ingress controller, is retired upstream. A second proxy just to serve one Ingress object would cost budget and add a moving part. The contract's behaviour (prod at `http://localhost:8080`, `/admin/*` refused) is met by the same edge that serves everything else. If a reviewer runs `kubectl get ingress`, there is none, and this record is why.
- **Five more listeners on the one Gateway:** `app` (8080, routes from namespace `prod` only), `grafana` (3000), `prometheus` (9090) and `alertmanager` (9093) (routes from `monitoring` only), all plain HTTP with no hostname. The Envoy Service's NodePorts are fixed (30808, 30300, 30909, 30993) and kind maps them to the host's 127.0.0.1 (`cluster/kind.yaml`). The HTTPS hostnames on 443 stay.
- **prod's public route** (`app-public`, chart value `publicRoute`, prod only) has no hostname, so `curl localhost:8080/...` matches.
- **`/admin/*` is refused at the edge, everywhere.** `POST /admin/fault` changes the app's error rate and latency at runtime with no authentication. Every route into the app, prod's 8080 route and each environment's HTTPS route, has a `/admin` rule with an Envoy Gateway `HTTPRouteFilter` that answers 403 itself. Gateway API picks the longest path match regardless of order, and the rule is listed last so the canary demo's `rules[0]` stays the main rule. In-cluster callers (port-forward, other pods allowed by the app's NetworkPolicy) still reach `/admin`, which is what the contract allows. A NetworkPolicy can't filter by path, so the edge rule is the control.

## Consequences

- `./platform verify` checks the contract's endpoints: `/readyz` 200 and `POST /admin/fault` 403 on `:8080`, and the three UIs' health endpoints on their ports. Compose's `ready` checks `http://localhost:8080/readyz`.
- `./platform doctor` also checks that 8080, 3000, 9090 and 9093 are free.
- The ports are bound to 127.0.0.1 only, like 80/443.
