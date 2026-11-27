# orders-gateway (server.js). A hardened Dockerfile:
# - the base image pinned by version and digest,
# - a numeric user, so Kubernetes can check runAsNonRoot (USER node is a
#   name it can't),
# - only what runs is copied: no tests, no dev files.
FROM node:22.23.5-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS app
ARG VERSION=dev
ENV VERSION=$VERSION NODE_ENV=production
# The app has no dependencies and runs as `node server.js`: npm, npx,
# corepack and yarn are never used at runtime, and npm's bundled packages
# are where the image's known vulnerabilities live (Trivy in CI). Remove them.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
      /usr/local/bin/corepack /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /srv
COPY package.json server.js ./
# The node image's "node" user, by number.
USER 1000:1000
EXPOSE 8080
CMD ["node", "server.js"]
