# 0023: Grafana dashboards as code, checked in CI

**Status:** Accepted, 2026-11-25

## Context

The brief asks for dashboards for every component, each panel with a plain-English description (sections 8 and 12), and the `docs/learn/` exercises compare a hand-built panel with "the provided dashboard". Grafana's sidecar (kube-prometheus-stack, `gitops/values/kube-prometheus-stack.yaml`) already loads any ConfigMap labelled `grafana_dashboard=1`, but until now none existed for the app.

## Choices

- **Source in `dashboards/<name>.json`**, the plain JSON Grafana exports, so it's easy to diff and to round-trip through the UI.
- **A generated ConfigMap per dashboard** in `gitops/manifests/monitoring/` (already applied by the `kube-prometheus-stack` Application), written by `scripts/dashboards.sh gen`. Kustomize's `configMapGenerator` can't read files outside its own folder, and the Argo CD Application is a plain directory, so a small generator is simpler than restructuring it.
- **`scripts/dashboards.sh check` in CI** (the `alerts` workflow, which already owns `alerts/` and `runbooks/`) fails when:
  - the ConfigMap is out of date with the JSON,
  - a panel has no description,
  - a PromQL query doesn't parse. The queries are wrapped as recording rules, with Grafana's variables filled in, and checked by the same pinned `promtool` as the alerts.
- **Datasources by fixed uid** (`prometheus`, `loki`), as provisioned by the chart, so the JSON works on any fresh cluster.
- **Error budget over 24 hours,** the Prometheus retention here (owner update 2026-11-23). The panel says so. Production would compute it over 30 days with long-term storage (README, Production differences).

## The `orders-gateway` dashboard

One `environment` variable (`orders-dev`, `orders-staging`, `orders-prod`, `orders-demo` while a demo runs). Rows:

1. **SLO:** availability and latency budget left (24 h), 1 h burn rates with the alert thresholds (14.4 and 6), burn rate over time, firing `OrdersGateway*` alerts.
2. **Traffic and errors:** requests/s by route and status (probes left out), 5xx share against 0.5%, orders created and rejected by reason, the payments call's errors and p95.
3. **Latency:** p50, p95 and p99 against 300 ms, and the exact share under 300 ms from the `le="0.3"` bucket.
4. **Versions, pods and resources:** pods by version (the canary split), CPU per pod as a share of its request against the HPA's 70%, memory against the limit.
5. **Logs:** warn and error lines from Loki.

An annotation marks when a new version starts.

## Tests

- `scripts/dashboards.sh check`: passes. It fails as expected with an emptied description, a broken query, or a stale ConfigMap (tried each).
- Every Prometheus query returns a result on the ogp cluster (`orders-prod`, after the #52 canary).
- The JSON imports into the cluster's Grafana 13.3.1 (imported under a test uid via the API, then deleted).
