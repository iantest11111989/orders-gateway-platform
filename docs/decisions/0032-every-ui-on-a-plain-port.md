# 0032: Every UI on a plain port, so nothing needs 80/443

**Status:** Accepted, 2026-11-25

## Context

The contract puts Grafana, Prometheus and Alertmanager on plain ports (decision 0028), but Argo CD's UI was only on `https://argocd.localtest.me`, port 443. On the owner's Mac mini that failed twice over: another program (a LAN dashboard's Caddy) held 443 and 80 on the Mac, and even without it, Colima can't forward ports below 1024 to the Mac's `127.0.0.1`, because macOS only lets root open them there and Colima runs as the user. The same dashboard's app held 3000, so the browser showed it instead of Grafana. `./platform doctor` missed all of it: it runs in the toolbox, inside Docker's VM, and sees the VM's ports, not the Mac's.

## Choices

- **Argo CD at `http://localhost:8081`:** one more plain-HTTP listener on the shared Gateway (routes from namespace `argocd` only), NodePort 30881, mapped by kind to the host's `127.0.0.1:8081`, like 0028's ports. Every UI now works from a browser with no root, no certificate and no `/etc/hosts`.
- **The HTTPS names stay, as an extra.** The README says they need 80/443 free and don't reach a Mac's browser under Colima.
- **`./platform doctor` (and `up`) check the Mac's own ports**, from the host before the toolbox starts. With no cluster, any listener on a contract port is a clash. With a cluster, each port must answer as its service (`/version`, Grafana's `/api/health`, Prometheus's and Alertmanager's `/-/ready`, Argo CD's `/api/version`); anything else is named. macOS only: on Linux the toolbox shares the host's network, so the in-toolbox check is already the right one.
- `./platform verify` checks Argo CD on `:8081` and logs in there (no port-forward).

## Consequences

- Clusters created before this lack the 8081 mapping (kind applies port mappings only at creation). `./platform up` says so and asks for `./platform down && ./platform up`.
- 8081 joins the ports that must be free on the host.
