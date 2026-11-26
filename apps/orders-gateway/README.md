# apps/orders-gateway

The service: `server.js`, a small Node.js app. You change its behaviour through environment variables. This folder also holds the `Dockerfile`, the tests (`server.test.js`) and the k6 scripts in `k6/`.

## Endpoints

| Endpoint | What it does |
| --- | --- |
| `GET /healthz` | 200 while the process answers (liveness) |
| `GET /readyz` | 503 for the first 3 s and after SIGTERM, otherwise 200 (readiness) |
| `GET /metrics` | Prometheus metrics: `http_requests_total`, `http_request_duration_seconds`, `app_info`, `app_ready`, `app_inflight_requests` |
| `GET /version` | the version and pod name |
| `GET /work?ms=N` | burns N ms of CPU (max 2000), which blocks every other request on that pod meanwhile |
| `POST /echo` | returns the body |
| `POST /admin/fault` | sets the error rate and added latency at runtime, with no authentication. Traefik refuses it from outside. |

Latency buckets run from 5 ms to 5 s. They include 250 ms (the SLO threshold) but not 300 ms.

## Logs

Each request is one JSON line with `ts`, `pod`, `version`, `level`, `msg`, `route`, `status`, `duration_ms` and a `trace_id` taken from the `traceparent` header. Probes and `/metrics` are not logged or counted. Unknown paths are logged with their raw path as `route`, so the ServiceMonitor keeps only the known routes.

## Configuration

`PORT` (default 8080), `VERSION`, `STARTUP_DELAY_MS` (how long `/readyz` stays 503 after start, default 3000), `FAULT_ERROR_RATE` (0 to 1) and `FAULT_LATENCY_MS`.

## Shutdown

On SIGTERM, `/readyz` turns 503 and the server stops taking new connections. It finishes the requests in flight, answering with `connection: close`, then exits. After 25 s it exits anyway.

The chart in [`helm/orders-gateway/`](../../helm/orders-gateway/README.md) sets the probes, the shutdown timing and the resources to match.

## Image and tests

The `Dockerfile` builds from `node:22.23.5-alpine`, pinned by digest, and runs as a non-root user. `npm test` and `npm run lint` run in the same Node image, locally in `./pipeline ci` and on pull requests in `.github/workflows/ci-app.yml`.
