# 0026: docker compose is the entry point; one `ready` service bootstraps the cluster

**Status:** Accepted, 2026-11-25

## Context

The assignment's fixed contract: the repo is run with `docker compose up -d --wait` on a fresh 8 vCPU / 16 GB x86-64 Linux VM, a Compose service named `ready` is healthy only when the platform is fully installed and the app is serving, the kubeconfig is written to `./out/kubeconfig.yaml`, long-running services have a restart policy, and data survives `docker compose stop`/`start`. Until now the entry point was `./platform up` (decision 0004).

## Choices

- **One long-running service, `ready`.** It runs the same pinned toolbox image as `./platform` (its tag is the hash of `toolbox/`; `scripts/check-compose-toolbox.sh` keeps `docker-compose.yml` in step in CI, and Compose builds it from `toolbox/` if the tag isn't published). Its command, `scripts/compose-ready.sh`, runs the existing idempotent `scripts/up.sh` (kind, then Argo CD, which installs everything else from Git), retrying on failure, writes the kubeconfig, then stays up. A separate one-shot bootstrap service would exit, and `--wait` treats an exited service as a failure.
- **Healthcheck = the contract's "ready".** `scripts/ready-check.sh` passes only when the bootstrap finished, every Argo CD Application is Synced and Healthy, and prod's `/readyz` answers. After that first success it only checks that prod is serving, so a demo, a paused canary or a short Degraded moment doesn't turn the whole platform unhealthy; a container restart brings the full check back. `start_period: 20m` covers a cold start (the brief allows 15 minutes; CI measures about 6–7).
- **Host network.** kind binds its API server and the platform's ports to the host's 127.0.0.1, so the kubeconfig kind writes works from the host unchanged.
- **The cluster lives outside Compose.** kind creates its node containers itself, so `docker compose stop`/`start` restarts only `ready`; its bootstrap re-runs against the running cluster and changes nothing. The cluster's data (Prometheus, Loki, Argo CD) is never stopped. `./platform down` deletes the cluster.
- **`./platform` stays** for everything after start-up (`verify`, `budget`, `demo`, `shell`) and for development. Both use the same toolbox image and the same `ogp-kube` volume.

## Consequences

- `docker compose down` removes `ready` but not the cluster; `./platform down` removes the cluster. Documented in the README.
- `./out/kubeconfig.yaml` is written by root inside the toolbox, with mode 0644 so the host user can read it. It's a local admin credential for a cluster bound to 127.0.0.1.
- CI's cluster job now starts the stack exactly the way a reviewer does, then checks the kubeconfig from the host and a stop/start cycle.

## Addendum, 2026-11-25: progress services

`docker compose up -d --wait` prints only each container's state, so with `ready` alone the reviewer saw "Waiting" for about nine minutes. Four services, `step-1-cluster` to `step-4-apps`, now do no work and only show progress: each one's healthcheck (`scripts/compose-step.sh`) passes when one stage is done (kind nodes Ready; the Git server and Argo CD running; every platform Application Synced and Healthy; dev, staging and prod Synced and Healthy), so Compose shows the stages turn Healthy in order. They share `ready`'s image and settings through a YAML anchor, including `restart: unless-stopped`; a passed step stays healthy until its container restarts, and re-derives its state from the cluster after `docker compose stop`/`start`. Each is an idle `sleep` process, outside the kind nodes. `./platform` now creates the `ogp-kube` volume with Compose's labels, so a later `docker compose up` adopts it without a warning.

## Addendum, 2026-11-25: `./platform down` means everything

The owner ran `./platform down`, then `docker compose up -d --wait`, and nothing came up. `down` had deleted the cluster but left `ready` running with its configuration unchanged, so Compose didn't recreate it, and an old `ready` that had finished its bootstrap just idled with no cluster. Two changes:

- **`./platform down` removes the Compose services first** (by Compose's project label, so it works without the Compose plugin), then deletes the cluster. Volumes are kept. The next `docker compose up` starts a fresh `ready`, which bootstraps.
- **`ready` watches its cluster.** After the bootstrap it checks every 30 s that the kind control plane exists; after two misses it exits, and `restart: unless-stopped` brings it back to rebuild the cluster. The step services tie their "passed" marker to the control plane's container ID, so after a rebuild they check again from the start.

