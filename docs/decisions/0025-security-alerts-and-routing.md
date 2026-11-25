# 0025: Security component alerts, and routing every alert to a local receiver

**Status:** Accepted, 2026-11-25

## Context

The brief (section 8) asks for alerts with runbooks on every component, and for Alertmanager to route them somewhere visible. Until now:
- **Our own alerts:** only the orders-gateway SLO burn rates (decision 0006).
- **The chart's alerts:** the defaults (TargetDown, Watchdog, KubePodCrashLooping, ...).
- **Routing:** Alertmanager sent everything to a `null` receiver, so an alert was only visible if someone opened its UI.

Argo CD, Rollouts and cert-manager alerts are in their own PR (claude_daddy's lane). This one covers the security components.

## Alerts (`alerts/platform-security.yaml`)

| Alert | Severity | Fires when | Why |
| --- | --- | --- | --- |
| `KyvernoDown` | **page** | no Kyverno admission controller scraped for 5 min | the webhooks fail open (`failurePolicy: Ignore`, decision 0022), so pods are admitted unchecked |
| `KyvernoPolicyErrors` | ticket | a policy returned `error` in the last 15 min | an erroring policy checks nothing |
| `SealedSecretsControllerDown` | ticket | no controller scraped for 10 min | new or changed SealedSecrets don't apply |
| `SealedSecretUnsealFailed` | ticket | a SealedSecret's `Synced` condition is False for 5 min | its Secret is stale or missing |
| `TrivyOperatorDown` | ticket | no operator scraped for 15 min | running images aren't scanned (CI's rescan still is) |
| `OrdersImageCriticalVulnerability` | ticket | a critical finding in an `orders-*` image for 30 min | our image only; third-party ones have known findings (decision 0021) |

Each has a runbook in `runbooks/` and promtool tests in `alerts/tests/platform-security.test.yaml`, including the case where the scrape target disappears entirely (`absent()`).

## Routing

Alertmanager posts every notification to **`alert-receiver`** in `monitoring`. It's 40 lines of Python standard library on the same pinned `python:3.14-alpine` image as the patch promoter (decision 0024). It writes each alert as one JSON log line, so alerts appear in Loki and Grafana next to the logs they explain:

```logql
{namespace="monitoring", app="alert-receiver"} | json | route="page"
```

The URL path records the route:
- **`/page`:** severity `page` (ours) or `critical` (the chart's). Waits 10 s, repeats hourly. Logged as `ERROR`.
- **`/ticket`:** `ticket` or `warning`. Repeats every 12 h. Logged as `WARN`.
- **`/log`:** everything else, such as `info`.
- **`/watchdog`:** the always-firing `Watchdog`, every 5 minutes. That line is the heartbeat that proves the whole path works: Prometheus → Alertmanager → receiver → Alloy → Loki.

Inhibit rules are the chart's defaults, plus the same rule for `page` over `ticket`.

## Production

`/page` would go to an on-call tool (PagerDuty, Opsgenie) and `/ticket` to a chat channel or ticket queue. `Watchdog` would go to a dead-man's switch that pages when the heartbeat *stops*.
