# app: orders-gateway

The service, `server.js`. Its behaviour changes only through configuration (environment variables). This folder adds a better `Dockerfile`, a `.dockerignore` and the k6 load script (`k6/load.js`).

## What it does (read from server.js)

| Endpoint | What it does |
| --- | --- |
| `GET /healthz` | always 200 while the process answers (liveness) |
| `GET /readyz` | 503 for `STARTUP_DELAY_MS` (3 s) after start and from SIGTERM on, else 200 (readiness) |
| `GET /metrics` | Prometheus text: `http_requests_total{route,method,status}`, `http_request_duration_seconds{route}` (buckets 5 ms … 5 s, with 250 ms and 500 ms but no 300 ms), `app_info{version}`, `app_ready`, `app_inflight_requests` |
| `GET /version` | the `VERSION` and pod name |
| `GET /work?ms=N` | **burns N ms of CPU (max 2000) on Node's single event loop**, blocking every other request on that pod meanwhile |
| `POST /echo` | returns the body |
| `POST /admin/fault` | **sets the error rate and added latency at runtime, with no authentication**; refused at the edge |

Probes, metrics and `/healthz` aren't counted or logged. Every other request is logged as one JSON line (`ts`, `pod`, `version`, `level` = `info` or `error`, `msg`, `route`, `status`, `duration_ms`, `trace_id` from a `traceparent` header). Unknown paths get their raw path as `route`, so the ServiceMonitor keeps only the known routes.

**Configuration:** `PORT` (8080), `VERSION`, `STARTUP_DELAY_MS` (3000), `FAULT_ERROR_RATE` (0–1), `FAULT_LATENCY_MS`.

**Shutdown:** on SIGTERM, `/readyz` turns 503, the server stops accepting connections, finishes in-flight requests (answering `connection: close`), and exits; it forces an exit after 25 s.

## How the chart runs it (helm/orders-gateway)

- `startupProbe` on `/healthz`, then `/readyz` for readiness (2 s timeout, 3 misses) and a lenient liveness (3 s timeout, 6 misses, 60 s): a `/work` call blocks the event loop, so strict probes would restart or drain busy pods during a spike.
- `preStop` sleeps 5 s so the endpoints drop the pod first; `terminationGracePeriodSeconds: 35` covers that plus the app's 25 s.
- `runAsUser: 1000` (the node image's user, by number), read-only root filesystem, no capabilities.
- CPU request 100m (what the HPA's 70% is measured against; `/work` is CPU), memory 48Mi request / 128Mi limit.

## Images

`Dockerfile` builds from `node:22.23.5-alpine`, pinned by digest. CI runs `npm test` and `npm run lint` in that same Node image (`.github/workflows/ci-app.yml` and `cd-app.yml`).
