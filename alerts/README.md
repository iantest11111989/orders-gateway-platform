# alerts

PrometheusRules, loaded by Prometheus through Argo CD (the observability PR wires this up). Every alert has a `runbook_url` pointing at a file in `runbooks/`.

| File | What it holds |
| --- | --- |
| `orders-gateway-slo.yaml` | SLI recording rules and multi-window burn-rate alerts for the orders-gateway SLO |
| `platform-delivery.yaml` | Argo CD app OutOfSync or unhealthy, the stack near its 12 GiB memory budget (all `ticket`) |
| `platform-security.yaml` | Kyverno, Sealed Secrets and Trivy Operator alerts |
| `tests/` | promtool unit tests, one file per rule file |

**Labels the promotion gate reads.** `./pipeline cd <app> <env>` refuses a promotion while an alert fires for that app in the environment it comes from (`scripts/promotion-gate.sh`: `ALERTS{namespace="<env>", service="<app>"}`). So an alert about one app keeps the `namespace` and `service` labels of its series (aggregate `by (namespace, service)`), and an alert about the platform as a whole carries neither.

Test locally (needs only Docker):

```sh
scripts/test-alerts.sh
```

It validates every rule file, runs the unit tests, and checks every alert's runbook link resolves.
