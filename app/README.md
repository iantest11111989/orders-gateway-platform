# orders-gateway

A small, stateless Go service that stands in for a real orders API. It has no database. It validates orders, simulates a call to a downstream payments service, and returns deterministic fake data for lookups. It uses the standard library (`net/http`, `log/slog`) plus the official Prometheus client.

## Endpoints

| Endpoint | Behaviour |
| --- | --- |
| `POST /orders` | Validates the JSON body, simulates the payments call, returns `201` with the order and a `Location` header. `400` with a `reason` on validation failure, `502` if the payments call fails. |
| `GET /orders/{id}` | Returns a fake order generated deterministically from the ID (`ord_` + 16 hex digits). `404` for malformed IDs. |
| `GET /healthz` | Liveness: `200` while the process is alive. |
| `GET /readyz` | Readiness: `503` during start-up warm-up (2 s) and from the moment shutdown starts. |
| `GET /metrics` | Prometheus metrics. |

Request body for `POST /orders`:

```json
{"customer_id": "cust-42", "items": [{"sku": "SKU-MUG-2", "quantity": 2}]}
```

Rules: `customer_id` is 1-64 letters, digits, `-` or `_`; 1-50 items; each `sku` is 1-32 uppercase letters, digits or `-`; `quantity` is 1-100. The body is at most 64 KiB, and **unknown fields are rejected**, so payment or card data can't be sent to the service by accident.

## Configuration

Environment variables only.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | Listen port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `PAYMENTS_LATENCY_MS` | `40` | Simulated payments call time (plus or minus 20%) |
| `PAYMENTS_ERROR_RATE` | `0` | 0-1: share of payments calls that fail (`502`) |
| `FAULT_ERROR_RATE` | `0` | 0-1: share of `/orders` requests that return `500` (demos) |
| `FAULT_LATENCY_MS` | `0` | Extra delay added to every `/orders` request (demos) |
| `APP_VERSION` | build version | Version reported in logs and `app_build_info` |

The service refuses to start, with a clear message, if any value is invalid. `FAULT_*` settings only affect `/orders` routes: probes and metrics keep working, so a fault demo breaks the API without Kubernetes restarting the pods.

## Shutdown

On `SIGTERM`, readiness fails immediately. The service keeps serving for 5 s so the gateway and Endpoints stop routing to the pod, then gives in-flight requests up to 20 s to finish. Including the 2 s warm-up, everything stays under the chart's 30 s `terminationGracePeriodSeconds`.

## Logs

JSON on stdout, one line per request:

```json
{"time":"…","level":"INFO","msg":"request","method":"POST","route":"/orders","status":201,"duration_ms":36.1,"request_id":"demo-1","version":"v1","order_id":"ord_d52a933e6f14972c"}
```

Level is `info` for successful requests, `warn` for `4xx`, and `error` for `5xx`. A request the client abandons (disconnect or timeout) before a response is written is recorded as **`499`** (the nginx/Envoy convention) at `warn`. It isn't a success, it isn't a server error, and it doesn't count as a payments failure; the SLO excludes it. Probe and scrape requests log at `debug`, so they're hidden by default. `X-Request-ID` is read from the request if it looks like an ID (otherwise a new one is generated) and returned in the response.

## Metrics

| Metric | Type | Labels |
| --- | --- | --- |
| `http_requests_total` | counter | `route`, `method`, `code` |
| `http_request_duration_seconds` | histogram, with a bucket at **0.3 s** (the SLO threshold) | `route`, `method` |
| `http_requests_in_flight` | gauge | |
| `payments_call_duration_seconds` | histogram | |
| `payments_call_errors_total` | counter | |
| `orders_created_total` | counter | |
| `orders_rejected_total` | counter | `reason` (fixed set, pre-initialised to 0) |
| `app_build_info` | gauge, always 1 | `version`, `commit` |
| `go_*`, `process_*` | Go runtime and process | |

`route` is always the route template (for example `/orders/{id}`), never the raw path. Unknown paths share `route="unmatched", method="other"`, so clients can't create new series.

## SLO

99.5% of `POST /orders` requests succeed (non-5xx) **and** complete in under 300 ms, over 30 days.

## Develop

Everything runs in containers; you don't need Go installed.

```sh
cd app
docker run --rm -v "$PWD":/src -w /src golang:1.27 go test -race ./...
docker build -t orders-gateway:dev .
docker run --rm -p 8080:8080 --read-only --cap-drop ALL orders-gateway:dev
curl -s -XPOST localhost:8080/orders -d '{"customer_id":"c1","items":[{"sku":"SKU-PEN-5","quantity":1}]}'
```

Load test with k6 (thresholds mirror the SLO; k6 exits non-zero if they fail):

```sh
docker run --rm --network host -v "$PWD/k6":/k6 -e BASE_URL=http://localhost:8080 -e RATE=50 -e DURATION=30s \
  grafana/k6:2.4.0 run /k6/load.js
```

## Image

Multi-stage build: Go cross-compiles on the build machine for each target architecture (`linux/amd64`, `linux/arm64`), and the result runs on `gcr.io/distroless/static-debian13:nonroot`. There's no shell or package manager, it runs as uid 65532, and it works with a read-only root filesystem and all capabilities dropped. Base images are pinned by digest. The image is about 18 MB.

### Published images

CI (`.github/workflows/app.yml`, job `publish`) pushes multi-arch images to `ghcr.io/iantest11111989/orders-gateway` from `main` only, after the tests and lint pass. Pull requests build without pushing.

| Tag | What | Built with |
| --- | --- | --- |
| `sha-<12 chars>`, `main` | This commit. Environments deploy by `sha-` tag. | defaults |
| `v1` | Demo: the normal app | `VERSION=v1` |
| `v2` | Demo: a visible change, `estimated_delivery` (2-5 days) on every order | `VERSION=v2`, `FEATURES=delivery-estimates` |
| `v2-bad` | Demo: v2 with fault injection on by default (10% 500s, +400 ms), so a canary fails its analysis and rolls back | as `v2`, plus `--target bad` |

There's no `:latest`. The demo tags are rebuilt from each `main` commit, so they always match the current code. Build any of them locally:

```sh
docker build --build-arg VERSION=v2 --build-arg FEATURES=delivery-estimates -t orders-gateway:v2 .
docker build --target bad --build-arg VERSION=v2-bad --build-arg FEATURES=delivery-estimates -t orders-gateway:v2-bad .
```
