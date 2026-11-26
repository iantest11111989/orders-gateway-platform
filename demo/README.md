# Demos

Each demo is a folder here, run with `./platform demo <name>`. It narrates each step and says where to watch.

| Demo | What happens | Time |
| --- | --- | --- |
| [`rolling-update`](rolling-update/run.sh) | v1 → v2 in a 3-pod copy of dev: pods replace one at a time; fails if fewer than 99.5% of requests meet the SLO | ~2 min |
| [`chaos`](chaos/run.sh) | in a copy of prod: delete a pod, then drain a worker; the disruption budget lets only one pod go at a time; fails if fewer than 99.5% of requests meet the SLO | ~3 min |
| [`gitops-revert`](gitops-revert/run.sh) | a bad config commit (30% of requests fail) on a temporary branch that a copy of dev follows; Argo CD syncs it, then `git revert` heals it. Pushes to the cluster's Git server | ~5 min |
| [`autoscale`](autoscale/run.sh) | in a copy of prod: k6 sends a fixed 20 requests/s (`AUTOSCALE_RATE`), mostly CPU-heavy `/work`; the HPA scales 3 → 6 pods, then back to 3 about 5 minutes after the load stops | ~8 min |
| [`policy`](policy/run.sh) | Kyverno refuses an unsigned image and a `:latest` image, printing which policy refused each and why; a signed image is admitted | <1 min |
| [`hello-world`](hello-world/) | a second app through the whole CI/CD, next to orders-gateway in dev, staging and prod: `./pipeline ci --version`, `cd` dev → staging → prod, a refused out-of-order promotion, a rollback, then its metrics and logs. It stays running to play with; `./platform demo hello-world clean` tears it down | ~6 min |

`./platform demo clean` deletes what a demo left (after an interrupted run, or `--keep`) and tears `hello-world` down.

**How they run.** The first five run in namespace `demo`, as a copy of the live prod (`chaos`, `autoscale`) or dev (`rolling-update`, `gitops-revert`) Argo CD Application: same chart, same values, same sync options. Only the name, namespace, Traefik entrypoint (`http://localhost:8084`) and the image under test differ, so the real environments only ever change through Git. k6 sends traffic through Traefik the whole time. They run in the toolbox and share [`lib.sh`](lib.sh): the demo copy, load and narration, the in-stack Git helpers, and what happens at the end (`--keep` leaves the copy running). `hello-world` has its own app, chart and env files and runs on the host, because it drives `./pipeline`.

Watch in Argo CD (`http://localhost:8081`) or Grafana (`http://localhost:3000`, environment `demo`).
