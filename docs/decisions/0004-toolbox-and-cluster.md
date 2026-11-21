# 0004: Toolbox container, ./platform CLI and the kind cluster

**Status:** Accepted, 2026-11-21

## Context

Reviewers must be able to run the stack with only Docker installed, on amd64 Linux and on arm64 Macs under Colima, within 6 CPU / 12 GB.

## Options

1. Ask reviewers to install kind, kubectl, helm and so on themselves.
2. A Makefile plus tool installers.
3. One toolbox image with every tool pinned, and a small POSIX `./platform` script that runs commands inside it.

## Choice

Option 3.

- **Toolbox:** `toolbox/Dockerfile` on `docker:29-cli` (pinned by digest, Alpine with the Docker CLI). `toolbox/versions.env` pins every tool. `install-tools.sh` downloads each tool for the target architecture and checks it against the SHA-256 checksum its project publishes with that release. The build fails on any mismatch.
- **Image tag:** a hash of the `toolbox/` directory (`sha-<12 hex>`), so any version change gives a new image. `./platform` pulls `ghcr.io/iantest11111989/orders-gateway-platform-toolbox:<tag>`, or builds it locally if that tag isn't published yet (for example on a branch).
- **How it runs:** the toolbox runs with `--network host` (so kind's loopback API server and ports work), the Docker socket mounted (so kind can create node containers), and the repo at `/work`.
- **Kubeconfig:** lives in the named volume `ogp-kube`, not in the repo. On macOS the repo is shared into the Colima VM with virtiofs, which enforces host file permissions. kind's lock file is created with mode 0000, so writing it there failed. A volume also keeps root-owned files out of Linux checkouts.
- **Cluster:** `cluster/kind.yaml` has 1 control plane and 2 workers on pinned `kindest/node:v1.37.0@sha256:…`.
  - **Zones:** `zone-a` (control plane and worker) and `zone-b` (worker2), so topology spread across zones is demonstrable.
  - **Ports:** host 80/443 map to NodePorts 30080/30443 for Envoy Gateway, bound to 127.0.0.1 only.
  - **Metrics:** the scheduler, controller-manager, etcd (`:2381`) and kube-proxy (`:10249`) bind their metrics endpoints to `0.0.0.0` so Prometheus can scrape them.
  - **NetworkPolicy:** kind's default CNI (kindnet) enforces it. This was verified: a default-deny policy blocked a working pod-to-pod request.
- **Resource caps:** kind has no resource settings, so `up` caps each node container with `docker update` at 2 CPU / 4 GiB, which adds up to the 6 CPU / 12 GiB budget. Under Colima the VM is already capped. On Linux this is what keeps the stack inside the budget.
- **Kubelet reservations:** a container cap alone is not enough. The kubelet reads the Docker host's CPU and memory, not the container's cgroup limit, so without help every node advertises the whole host (6 CPU / 11.7 GiB on the Mac). The scheduler would overcommit, and the kernel's cgroup OOM killer, not the kubelet, would pick what dies (possibly etcd or the kubelet itself).
  - **Fix:** at create time `up` reads the host totals from `docker info` and adds a `KubeletConfiguration` patch to every node:
    - `systemReserved` = host − cap (+ 256 Mi headroom)
    - `evictionHard: memory.available: 200Mi`
  - **Result:** each node advertises 2 CPU / about 3.6 GiB allocatable.
  - **Check:** `up` then asserts allocatable ≤ cap on every node, and fails with "recreate it: `./platform down && ./platform up`" for clusters created before this existed.

## Consequences

- Reviewers run `./platform up` and nothing else. The first run builds or pulls a toolbox of about 1.3 GB (the argocd, k6, cosign and kubectl binaries are most of it).
- **Docker socket:** mounting it gives the toolbox root-equivalent access to the Docker host. Anything running in the toolbox could start privileged containers. That's inherent to kind-in-Docker and acceptable for a local demo, but don't run the toolbox on a machine you don't control.
- **Checkout location:** under Colima the checkout must be inside `$HOME` (Colima's default share). `./platform` checks this and says so if Docker can't see the repo.
- Checksums are fetched from the same release as the binaries. That protects against corrupted or swapped downloads, but not against a compromised release. Verifying cosign or GPG signatures where projects publish them is a possible follow-up for the supply-chain work.
- With hard per-node caps, a busy node can be throttled while others sit idle. `./platform budget` (coming) will measure real use.
