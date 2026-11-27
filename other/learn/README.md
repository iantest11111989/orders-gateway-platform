# Learn

Short hands-on exercises, about 15 minutes each, run against your live stack.

0. [A tour of the repo](00-repo-tour.md). Start here.
1. [Prometheus: your first queries](01-prometheus.md)
2. [Grafana: build a panel, then compare it to the dashboard](02-grafana.md)
3. [Loki: filter logs, parse JSON, turn logs into a metric](03-loki.md)
4. [SLOs: break the app, watch the error budget burn](04-slos.md)
5. [Kubernetes operations: Argo CD, rolling updates and Kyverno](05-k8s-operations.md)

## Where things are

| | URL | Login |
| --- | --- | --- |
| Grafana | <http://localhost:3000> | `admin` / `admin12345` |
| Argo CD | <http://localhost:8081> | `admin` / `admin12345` |
| Prometheus | <http://localhost:9090> | none |
| Alertmanager | <http://localhost:9093> | none |
| The app | prod <http://localhost:8080>, dev <http://localhost:8082>, staging <http://localhost:8083> | none |

## About the numbers

The expected numbers in each exercise are for k6's traffic only. A small background client (`stack/observability/trickle`) also sends `GET /work?ms=10` and `POST /echo` to every environment twice a second, so dev's `/work` and `/echo` rates read about 2/s higher each.
