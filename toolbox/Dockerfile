# syntax=docker/dockerfile:1
# The toolbox carries every pinned tool the platform needs, so Docker is the
# only thing you install. ./platform runs commands inside it.

# docker:29-cli (multi-arch index digest): Alpine with the Docker CLI, which
# kind needs to create its node containers through the mounted socket.
FROM docker:29-cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d AS base

FROM base AS tools
RUN apk add --no-cache curl
ARG TARGETARCH
COPY versions.env /tmp/versions.env
COPY install-tools.sh /usr/local/bin/install-tools.sh
RUN install-tools.sh "$TARGETARCH" /out

FROM base
RUN apk add --no-cache bash curl git openssl ca-certificates
COPY --from=tools /out/ /usr/local/bin/
COPY versions.env /etc/toolbox-versions.env
ENV KUBECONFIG=/root/.kube/config
WORKDIR /work
CMD ["bash"]
