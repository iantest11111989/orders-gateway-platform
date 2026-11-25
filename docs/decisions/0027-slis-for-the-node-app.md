# 0027: SLIs for the Node app, and keeping its metrics bounded

**Status:** Accepted, 2026-11-25

## Context

The assignment's app (`app/server.js`) replaces our Go stand-in. Its metrics differ from what decision 0006 was written for:

- `http_requests_total{route, method, status}`: `status`, not `code`.
- `http_request_duration_seconds{route}`: a histogram with **only a `route` label**, buckets .005 … .1, .25, .5 … 5 s. There is no 0.3 bucket.
- `app_info{version}`, `app_ready`, `app_inflight_requests`.
- `route` is the raw path for any path the app doesn't know (`/admin/*` is folded into `/admin`). Probes and `/metrics` aren't counted at all.

Its routes: `/work?ms=N` burns N ms of CPU (up to 2 s) on the single event loop; `POST /echo` returns its body; `/version`; `POST /admin/fault` (in-cluster only, decision 0028). `GET /echo` and unknown paths are 404.

## Decision

**Availability SLI:** 5xx answers on `/work` and `/echo`, out of their answers that weren't 4xx. A 4xx (`GET /echo`, say) is the caller's mistake: neither good nor bad. `/version` is left out of availability because it can't fail except when the whole pod is down, which the other two routes show too.

**Latency SLI:** `/echo` and `/version` answered within 250 ms (the `le="0.25"` bucket, so the ratio is exact, not interpolated). **`/work` is left out of latency**: the caller chooses its latency with `?ms=`, and since the histogram has no other label, `/work?ms=10` and `/work?ms=2000` share one series. An SLO on it would measure the caller, not us; under the "sharply rising traffic" the graders send it would page on their own choice of `ms`. `/work` still shows up where it should: in availability, in the dashboard's request panels, and in the autoscaler (it is the CPU). Saturation from long `/work` calls *does* reach the latency SLI, because one blocked event loop delays every request on that pod, `/echo` included. That is the user-visible symptom we want.

**Both 99.5% over 30 days**, with the multi-window burn-rate alerts of decision 0006 unchanged (14.4x over 1 h and 5 m pages; 6x over 6 h and 30 m tickets). The recording rule names (`slo:orders_*`) are kept, so the promoter, the overview dashboard and the alerts didn't need new names.

**The canary analysis** (the demo copy's AnalysisTemplate) uses the same two SLIs on the canary's pods: 5xx ratio ≤ 0.5% on `/work|/echo`, and p99 ≤ 250 ms on `/echo|/version`.

**Bounded cardinality:** the ServiceMonitor keeps `http_requests_total` and `http_request_duration_seconds_*` series only for the app's own routes (`/work`, `/echo`, `/version`, `/admin`) and drops the rest at scrape. We drop rather than rename to `route="other"`: renaming would make several series with the same remaining labels collide within one scrape (`/foo` and `/bar`, both `GET 404`), which Prometheus rejects as duplicates. Unknown paths stay visible in the app's logs (Loki) and in Envoy's metrics. The ingress still forwards them, because the contract says everything the app serves must be reachable, its 404 included.

**The patch promoter** (decision 0024) soaks on `app_info{version}` and needs 300 `/work` + `/echo` requests in the hour; its trickle sends a `GET /work?ms=10` and a `POST /echo` to each environment every half second.

## Consequences

- A grader's `/work?ms=2000` flood can't page us through latency on its own; if it saturates pods, `/echo` slows and *that* pages, which is the right signal.
- No method label on the histogram, so latency can't be split by method; fine for these routes.
- Scanners hitting random paths cost log lines, not series.
- Revisit if the app gains a route template label or per-route buckets: `/work` could then get its own SLO relative to the `ms` asked for.
