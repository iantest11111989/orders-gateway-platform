# docs/learn

Hands-on, roughly 15-minute exercises for Prometheus, Grafana, Loki, SLOs and Kubernetes operations, run against the live cluster.

0. [The work test, element by element](00-the-work-test.md): start here. A tour of the assignment, top to bottom, on your own stack, pointing into 1–5 where they fit.
1. [Prometheus: your first queries](01-prometheus.md)
2. [Grafana: build a panel, then compare it to the dashboard](02-grafana.md)
3. [Loki: filter logs, parse JSON, turn logs into a metric](03-loki.md)
4. [SLOs: break the app, watch the error budget burn](04-slos.md)
5. [Kubernetes operations: Argo CD, Rollouts and Kyverno](05-k8s-operations.md)

**Expected numbers:** the numbers in each exercise are for k6's traffic alone. The patch promoter's trickle ([decision 0024](../decisions/0024-patch-promoter.md)) also sends a `GET /work?ms=10` and a `POST /echo` to every environment about twice a second, so dev's `/work` and `/echo` rates read about 2/s higher each. To see exactly how much, run `sum by (route) (rate(http_requests_total{namespace="dev"}[5m]))` in Prometheus before you start k6. (Scaling the trickle to 0 doesn't help: Argo CD's self-heal puts it back within seconds.)

**Where things are:** Grafana <http://localhost:3000> (`admin` / `admin12345`), Prometheus <http://localhost:9090>, Alertmanager <http://localhost:9093>, the app in prod <http://localhost:8080>. dev and staging are reached through the gateway's HTTPS hostnames, `https://orders.dev.localtest.me` and `https://orders.staging.localtest.me` (`*.localtest.me` resolves to 127.0.0.1; the certificate is from the stack's own demo CA, hence `--insecure-skip-tls-verify` / `curl -k`).
