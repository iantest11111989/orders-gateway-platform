# docs/learn

Hands-on, roughly 15-minute exercises for Prometheus, Grafana, Loki, SLOs and Kubernetes operations, run against the live cluster.

1. [Prometheus: your first queries](01-prometheus.md)
2. [Grafana: build a panel, then compare it to the dashboard](02-grafana.md)
3. [Loki: filter logs, parse JSON, turn logs into a metric](03-loki.md)
4. [SLOs: break the app, watch the error budget burn](04-slos.md)
5. [Kubernetes operations: Argo CD, Rollouts and Kyverno](05-k8s-operations.md)

**Expected numbers:** the numbers in each exercise are for k6's traffic alone. The patch promoter's trickle ([decision 0024](../decisions/0024-patch-promoter.md)) also sends a steady stream of orders (`customer_id` `cust-trickle`) to every environment, so dev's `201` rate reads that much higher. To know by how much, run `sum(rate(http_requests_total{namespace="orders-dev", route="/orders", method="POST"}[5m]))` in Prometheus before you start k6. (Scaling the trickle to 0 doesn't help: Argo CD's self-heal puts it back within seconds.)
