# orders-gateway: the assignment's app (server.js, unchanged). A better
# Dockerfile than the one it came with, as the rules allow:
# - the base image pinned by version and digest (Renovate keeps it current),
# - a numeric user, so Kubernetes can check runAsNonRoot (USER node is a
#   name it can't),
# - only what runs is copied: no tests, no dev files,
# - a `bad` target for the v2-bad demo image, which differs only by
#   configuration (FAULT_* environment variables the app reads).
FROM node:22.23.5-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS app
ARG VERSION=dev
ENV VERSION=$VERSION NODE_ENV=production
WORKDIR /srv
COPY package.json server.js ./
# The node image's "node" user, by number.
USER 1000:1000
EXPOSE 8080
CMD ["node", "server.js"]

FROM app AS bad
ENV FAULT_ERROR_RATE=0.1 FAULT_LATENCY_MS=400

FROM app
