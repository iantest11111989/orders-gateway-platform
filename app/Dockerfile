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
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.buildVersion=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/orders-gateway .

# gcr.io/distroless/static-debian12:nonroot (multi-arch index digest):
# no shell, no package manager, runs as uid 65532.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/orders-gateway /orders-gateway
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/orders-gateway"]
