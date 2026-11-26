# demo/hello-world

The second app of `./platform demo hello-world`: a tiny service that answers `hello world`. It isn't one of the repo's apps. The demo copies it into the checkout (`apps/hello-world/`, `helm/hello-world/`, `cd/hello-world/`), takes it through the whole local CI/CD with `./pipeline` (`ci`: test, build, scan, publish; `cd`: dev, then staging, then prod through the promotion gate; a rollback), shows its logs and dashboards next to orders-gateway's, then removes it again.

- `app/`: the service (`server.js`, no dependencies), its test, and a hardened Dockerfile (pinned base, non-root, works with a read-only root filesystem). It serves `/`, `/version`, `/healthz`, `/readyz` and `/metrics`, with the same metric names as orders-gateway, so the platform's dashboards and log queries work for it unchanged.
