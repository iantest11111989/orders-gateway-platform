# 0007: Observability stack layout, sizing and security

**Status:** Accepted, 2026-11-21

## Context

The brief (section 8) asks for kube-prometheus-stack (Prometheus with 2-day retention, Alertmanager, Grafana, kube-state-metrics, node-exporter, Prometheus Operator), Loki in single-binary mode, and Alloy as a DaemonSet with only `namespace`, `app`, `env` and `pod` as log labels. Every component needs metrics and logs. It must fit the 6 CPU / 12 GB budget next to everything else, and run as close to Pod Security "restricted" as each component allows (section 9).

## Choices

**Applications** (all in `gitops/apps/templates/`, waves from decision 0005):

| Application | Wave | Namespace | Pod Security enforce |
| --- | --- | --- | --- |
| `prometheus-operator-crds` | -10 | (cluster-scoped) | n/a |
| `kube-prometheus-stack` | 20 | `monitoring` | privileged (node-exporter only, see below) |
| `loki` | 20 | `logging` | restricted |
| `alloy` | 20 | `logging` | restricted |
| `platform-alerts` (`alerts/`) | 25 | `monitoring` | n/a (rules only) |

**CRDs separately.** The operator CRDs come from the upstream `prometheus-operator-crds` chart at wave -10, and kube-prometheus-stack runs with `crds.enabled: false`. The two charts' operator versions must match (v0.95.2 today); Renovate will group them.

**Prometheus** picks up every ServiceMonitor, PodMonitor, Probe, ScrapeConfig and PrometheusRule in the cluster (`*SelectorNilUsesHelmValues: false`), so other charts only need `serviceMonitor.enabled: true`. Retention is 2 days (also capped at 4 GB) on a 5 Gi volume from kind's `standard` (local-path) class. Several high-cardinality API server and cAdvisor series that nothing here uses are dropped.

**Loki** is one pod: filesystem storage on a 5 Gi volume, TSDB schema v13, retention of 48 h through the compactor. The memcached caches, the nginx gateway, the canary and the ruler are all off. At this log volume, the caches would cost more memory than Loki itself.

**Alloy** tails logs **through the Kubernetes API** (`loki.source.kubernetes`), not from `/var/log/pods` on the host. Each DaemonSet pod only watches pods on its own node (field selector on `NODE_NAME`), so the load is spread and nothing is read twice. The trade-off is more API server traffic than file tailing. In return Alloy needs no `hostPath` volumes, runs as `nobody` with a read-only root filesystem, and its namespace can enforce "restricted". Its RBAC is cut down to `pods`, `pods/log` and `namespaces`. The chart's default role can read every Secret in the cluster.

Log labels: `namespace`, `pod`, `app` (first of `app.kubernetes.io/name`, `app`, `k8s-app`, `component`) and `env` (the pod's `env` label, else `platform`). Fields such as `level`, `route` and `request_id` are parsed at query time with `| json`, so they never become labels.

**JSON logs everywhere we can:** Argo CD, Grafana, Loki and Alloy are switched to JSON in their values.

**node-exporter is the one Pod Security exception.** It needs `hostNetwork`, `hostPID` and read-only `hostPath` mounts of `/proc`, `/sys` and `/`, which only "privileged" allows. The `monitoring` namespace therefore *enforces* privileged, but *audits* and *warns* at restricted, so any other non-compliant pod there still shows up. The Kyverno PR will enforce the restricted rules on every other pod in `monitoring`, with an exception for node-exporter only.

**Admission webhook off (for now).** The Prometheus Operator's validating webhook needs a TLS certificate from a hook Job or from cert-manager. Until cert-manager lands (gateway PR), rules are validated by promtool in CI. Re-enable it with cert-manager afterwards.

## Sizing (requests / limits, memory)

| Component | Request | Limit |
| --- | --- | --- |
| Prometheus (+ config reloader) | 768 Mi (+16) | 1.5 Gi (+32) |
| Alertmanager (+ reloader) | 32 Mi (+16) | 64 Mi (+32) |
| Grafana + 2 sidecars | 256 + 2 × 64 Mi | 512 + 2 × 128 Mi |
| Prometheus Operator | 64 Mi | 128 Mi |
| kube-state-metrics | 64 Mi | 128 Mi |
| node-exporter (× 3) | 32 Mi | 64 Mi |
| Loki | 256 Mi | 512 Mi |
| Alloy + reloader (× 3) | 96 + 16 Mi | 192 + 32 Mi |
| **Total requested** | **about 2.0 Gi** | |

These are first estimates. The numbers measured on the running stack replace them in the budget PR (`./platform budget`). Prometheus prefers a different node from Loki (soft anti-affinity), so a log burst can't starve it.

## Consequences

- One `./platform up` gives metrics and logs for every pod, with no host access for log collection.
- API-based log tailing costs some API server CPU; `./platform budget` will show how much. If it's too much, switch to file tailing and accept a privileged `logging` namespace.
- **DEMO ONLY:** Grafana uses the chart's fixed login (`admin` / `prom-operator`) until the Sealed Secrets PR replaces it with a sealed secret.
- Dashboards, Alertmanager routing to a visible receiver, the platform alerts beyond the SLO ones, and Grafana/Prometheus behind the gateway come in follow-up PRs.
