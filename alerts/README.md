# alerts

PrometheusRules, loaded by Prometheus through Argo CD (the observability PR wires this up). Every alert has a `runbook_url` pointing at a file in `runbooks/`.

| File | What it holds |
| --- | --- |
| `orders-gateway-slo.yaml` | SLI recording rules and multi-window burn-rate alerts for the orders-gateway SLO ([decision 0006](../docs/decisions/0006-slo-rules.md)) |
| `platform-security.yaml` | Kyverno, Sealed Secrets and Trivy Operator alerts ([decision 0025](../docs/decisions/0025-security-alerts-and-routing.md)) |
| `tests/` | promtool unit tests, one file per rule file |

Test locally (needs only Docker):

```sh
scripts/test-alerts.sh
```

It validates every rule file, runs the unit tests, and checks every alert's runbook link resolves.
