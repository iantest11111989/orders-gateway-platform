# alerts

Prometheus alert rules. Argo CD loads them as the `platform-alerts` Application. Every alert has a `runbook_url` that points at a file in [`stack/observability/runbooks/`](../runbooks/README.md).

| File | What it holds |
| --- | --- |
| `orders-gateway-slo.yaml` | SLI recording rules and burn-rate alerts for the orders-gateway SLOs |
| `platform-delivery.yaml` | Argo CD apps out of sync or unhealthy, a manual Sync waiting over an hour, the stack near its 12 GiB memory budget. All are tickets. |
| `platform-security.yaml` | Kyverno, Sealed Secrets and Trivy Operator alerts |
| `tests/` | promtool unit tests, one file per rule file |

## Labels the promotion gate needs

`./pipeline cd <app> <env>` refuses to promote while an alert fires for that app in the environment it promotes from. The gate (`scripts/promotion-gate.sh`) looks for `ALERTS{namespace="<env>", service="<app>"}`.

So:

- An alert about one app keeps the `namespace` and `service` labels. Aggregate with `by (namespace, service)`.
- An alert about the platform as a whole carries neither label.

## Test

```sh
scripts/test-alerts.sh
```

This needs only Docker. It validates every rule file, runs the unit tests and checks that every runbook link resolves.
