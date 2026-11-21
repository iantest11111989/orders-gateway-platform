# 0006: How the orders-gateway SLO is measured and alerted

**Status:** Accepted, 2026-11-21

(0005 is the `gitops/` layout record.)

## Context

The brief's SLO: 99.5% of `POST /orders` requests succeed (non-5xx) **and** complete in under 300 ms, over 30 days. Alerts must be multi-window burn-rate alerts: fast (about 14x over 1 h, page) and slow (about 6x over 6 h, ticket), for availability and for latency.

The app exposes `http_requests_total{route,method,code}` and a `http_request_duration_seconds{route,method}` histogram with a bucket at exactly 0.3 s (PR #2). The histogram has no `code` label.

## Options

1. **One combined SLI** ("good" = non-5xx **and** under 300 ms). This needs a single series that knows both status and duration: either a `code` label on the histogram (more series) or a dedicated good-events counter in the app.
2. **Two SLIs**, availability and latency, each with the full 0.5% budget and its own burn-rate alerts, built from the existing metrics.
3. Generate the rules with an SLO tool (Sloth, Pyrra).

## Choice

Option 2, with hand-written rules in `alerts/orders-gateway-slo.yaml`:

- **Availability:** bad = `code=~"5.."`, valid = every `code` except `499`.
- **Latency:** bad = slower than 300 ms, computed as `1 - bucket{le="0.3"} / count`.
- **Burn rates:** 14.4x over 1 h and 5 m, `for: 2m`, `severity: page`; 6x over 6 h and 30 m, `for: 15m`, `severity: ticket`. These are the Google SRE workbook values. The short window lets an alert clear soon after a fix.
- **Grouping:** everything is aggregated `by (namespace)`, so each environment has its own SLIs and alerts.
- **Tests:** promtool unit tests in `alerts/tests/` cover fast burn, slow burn, 499 exclusion, latency, healthy traffic and a short blip. `scripts/test-alerts.sh` runs them in CI and checks that every alert's `runbook_url` points at an existing file in `runbooks/`.

**Why exclude 499?** The app records 499 when the client gives up before a response is written (PR #2). That isn't a server failure, so it isn't bad. The server didn't serve it either, so it isn't good. Counting 499s as good would let a slow outage, where clients time out, look healthy.

**Why not a tool?** Sloth and Pyrra generate the same rules, but hand-written rules are easier to learn from, and teaching is one of this project's goals. Sloth would be the next step with many services.

## Consequences

- Two SLIs are slightly stricter than one combined SLI: a request that is both slow and a 5xx spends both budgets. That's acceptable, and simpler to explain.
- The latency SLI includes 499 requests in its denominator, because the histogram has no `code` label. Abandoned requests are usually slow, so they count as latency misses, which is the honest answer.
- A namespace that has never returned a 5xx reports an availability ratio of 0, not "no data". This is done with `or 0 * sum(...)`.
- **Open question for the owner:** Prometheus keeps **2 days** of data (brief, section 8), but the SLO window is **30 days**. Burn-rate alerts only need 6 hours, so they're unaffected. A true 30-day "error budget remaining" panel can't be computed from 2 days of data, though. The dashboard PR will either show the budget over the retained window, clearly labelled, or need a retention change. That's for the owner to decide.
