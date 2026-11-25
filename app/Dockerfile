# syntax=docker/dockerfile:1
# Multi-arch build: the Go toolchain runs on the build machine's native
# platform and cross-compiles for TARGETARCH, so arm64 and amd64 images build
# quickly without emulation.

# golang:1.27-alpine (multi-arch index digest)
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY *.go ./
ARG TARGETOS TARGETARCH
ARG VERSION=dev
ARG COMMIT=unknown
# Build-time features: "delivery-estimates" makes the v2 demo image.
ARG FEATURES=
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.buildVersion=${VERSION} -X main.commit=${COMMIT} -X main.buildFeatures=${FEATURES}" \
      -o /out/orders-gateway .

# gcr.io/distroless/static-debian13:nonroot (multi-arch index digest):
# no shell, no package manager, runs as uid 65532.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5 AS app
COPY --from=build /out/orders-gateway /orders-gateway
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/orders-gateway"]

# The v2-bad demo image (--target bad): fault injection on by default, so a
# canary's analysis sees 10% errors and p99 above the 300 ms SLO and rolls
# back. The chart sets FAULT_* only when its values ask for it, so these
# defaults survive. Never deploy this outside the canary demo.
FROM app AS bad
ENV FAULT_ERROR_RATE=0.1 FAULT_LATENCY_MS=400

# Default target: the normal image.
FROM app
