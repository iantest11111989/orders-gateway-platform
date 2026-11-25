# 0020: The canary demos run in a copy of prod

**Status:** Accepted, 2026-11-24 (the owner chose this on Telegram)

## Context

The brief (section 11) asks for `./platform demo canary`: "promote `v2` in prod; watch Rollouts step through traffic weights and pass analysis", then `canary-fail` with `v2-bad`. But prod only changes through Git: Argo CD syncs `orders-prod` from this repository's `main`, with self-heal on. A reviewer running the demo on their own machine can't push to the repository, and a change made to prod in the cluster is undone by self-heal within seconds.

## Options

- **A. A copy of prod** (`orders-demo`), made at demo time from the live `orders-prod` Application. The demo changes the copy's image, Argo CD syncs it and Rollouts runs the real canary. The copy is deleted afterwards.
- **B. Override prod's image in the cluster**, with the root app told to ignore Application parameter overrides. That is literally prod, but it opens a way to change prod outside Git that stays open after the demo.

## Choice

**A.** `scripts/demo.sh` copies the `orders-prod` Application object: same chart, same `environments/prod/values.yaml`, same `ignoreDifferences`, sync options and namespace Pod Security labels. Only the name and namespace (`orders-demo`), the hostname (`orders-demo.localtest.me`) and the image (Helm parameters `image.tag`, `image.digest`) differ. So the demo follows prod's configuration as it is in Git, without a second copy of it to keep in step. Changing the copy's Helm parameter is the demo's stand-in for the Git commit a real promotion would be. The AnalysisTemplate queries by `.Release.Namespace`, so the analysis follows the copy.

k6 (`app/k6/load.js`) sends about 10 requests per second through the gateway during the demo, because without traffic the analysis is Inconclusive and the canary pauses at 10% (decision 0011).

## Consequences

- Real prod never changes during a demo, and stays pure GitOps.
- The demo needs room for a second prod: the HPA's minimum replicas plus the canary pods. `./platform budget --watch` shows the peak while it runs.
- Policy audit results include the `orders-demo` namespace while it exists. The SLO alerts may fire for it during `canary-fail`, which is the point of that demo.
- `./platform demo clean` deletes the copy if a demo is interrupted; `--keep` leaves it running to look around.
