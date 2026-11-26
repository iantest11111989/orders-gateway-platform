# hello-world (server.js), the hello-world demo's second app. Built like
# orders-gateway: the base image pinned by version and digest, a numeric
# non-root user, and only what runs is copied (read-only root FS works: it
# writes nothing).
FROM node:22.23.5-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS app
ARG VERSION=dev
ENV VERSION=$VERSION NODE_ENV=production
# npm, npx, corepack and yarn never run; their bundled packages are where the
# base image's known vulnerabilities live (Trivy). Remove them.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
      /usr/local/bin/corepack /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /srv
COPY package.json server.js ./
USER 1000:1000
EXPOSE 8080
CMD ["node", "server.js"]
