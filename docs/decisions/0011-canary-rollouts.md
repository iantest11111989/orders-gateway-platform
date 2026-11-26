# 0011: Prod canary with Argo Rollouts, Gateway API weights and SLO analysis

**Status:** Accepted, 2026-11-23

## Context

The brief (section 7) asks for prod releases as canaries: about 10% → 25% → 50% → 100% of traffic, shifted by Gateway API `HTTPRoute` weights, with an `AnalysisTemplate` that checks the canary's 5xx rate and p99 latency against the SLO at each step and rolls back automatically on failure. The app must stay a normal Deployment in Git, with a Rollout using `workloadRef`. The Rollouts dashboard goes behind `rollouts.localtest.me`.

## Choices

- **Argo Rollouts** v1.10.2 (chart 2.43.12), wave 10, namespace `argo-rollouts` with PSA restricted. One controller replica, JSON logs, a ServiceMonitor, and RBAC only for the Gateway API provider.
- **Gateway API traffic router plugin v0.17.0** (2026-09-01). The newer v0.18.0 was five days old, so I skipped it. The controller loads plugins from one URL, but the plugin ships one binary per CPU architecture: arm64 on the Mac mini's Colima, amd64 in CI. An init container (alpine pinned by digest, restricted security context) downloads the right binary, **checks its sha256** (from the GitHub release metadata), and hands it to the controller through an `emptyDir` as `file:///plugins/gatewayapi-plugin`.
- **Chart, `rollout.enabled`** (on in prod only):
  - The Deployment is unchanged and remains the source of truth. The Rollout references it with `workloadRef` (`scaleDown: progressively`), so `kubectl get deploy` shows 0 replicas in prod; that's documented in the chart README.
  - The HPA targets the Rollout, and the Deployment leaves `replicas` out.
  - There are two extra Services, `-stable` and `-canary`. The HTTPRoute lists both, with weights 100/0, and the plugin edits those weights.
  - The `orders-prod` Argo CD Application ignores `.spec.rules[].backendRefs[]?.weight` (the `?` skips the /admin rule, which has no backends) (`RespectIgnoreDifferences`), so self-heal doesn't reset a canary in flight.
- **Steps:** setWeight 10 → analysis → 25 → analysis → 50 → analysis → 100.
- **AnalysisTemplate `orders-gateway-slo`** queries Prometheus about the canary pods only. The ServiceMonitor copies the `rollouts-pod-template-hash` pod label onto the metrics, and the Rollout passes the canary hash (`podTemplateHashValue: Latest`). It checks two things, both straight from the SLO: the 5xx ratio of `POST /orders` (excluding 499) must be ≤ 0.5%, and p99 latency must be ≤ 300 ms. Each check waits 60 s so the 1-minute rate window has samples, then measures every 30 s, 4 times. The 2nd failed measurement aborts.
- **Fails closed on missing data.** Both `successCondition` and `failureCondition` require a non-empty, non-NaN result, so "no canary traffic" is *Inconclusive*, never a pass. A 2nd inconclusive measurement (`inconclusiveLimit: 1`) pauses the rollout for a human. The error query uses the SLO rules' `or 0 * total` fallback, so a canary with traffic and zero 5xx returns 0 rather than nothing. (The first version treated empty as a pass, and v2-bad slipped through the 10% step; claude_momma's review caught that this was the real bug.)
- **Dashboard read-only** at `https://rollouts.localtest.me`, since it has no login. Promote and abort with `kubectl argo rollouts` in the toolbox, which already ships the plugin at v1.10.2.

## Tests (live on ogp, scratch namespace with prod values and the real GHCR images, ~10 requests/s of load)

| Change | Result |
| --- | --- |
| v1 → v2 (first version) | Weights 90/10 → 75/25 → 50/50 → 100% v2, every analysis Successful (p99 ≈ 50 ms, no 5xx), Healthy in about 2.5 min with 20 s test intervals. Responses then carry `estimated_delivery`. |
| v2 → v2-bad, no initial delay | Passed 10% (empty first measurement), aborted at 25%: p99 failed (2) > failureLimit (1). Weights back to 100% stable. |
| v2 → v2-bad, `initialDelay: 60s` | Aborted at 10% after about 1.5 min. |

Final version (fail closed, `initialDelay: 60s`, production intervals):

| Change | Result |
| --- | --- |
| v1 → v2, with load | Promoted: 90/10 → 75/25 → 50/50 → 100%. The first 10% measurement was Inconclusive (within the limit), then every measurement passed: 5xx ratio 0, p99 ≈ 50 ms. About 8 min. |
| v2 → v2-bad, with load | **Aborted at 10%**: p99 0.498 s twice, error ratio 5.2% and 10.7%. Weights back to 100% stable, `Degraded` (`RolloutAborted`). |
| v2 → v1, **no load** | **Paused at 10%** (`InconclusiveAnalysisRun`): every measurement Inconclusive, nothing promoted. |

## Resource impact

Argo Rollouts controller 25m/64Mi (limit 256Mi), dashboard 10m/32Mi (limit 128Mi), and the init container 10m/16Mi for a few seconds. During a canary, prod runs extra pods for the canary share (at most +3 with the steps above).

## Consequences

- The Deployment shows 0/0 in prod, which is expected; documented.
- Helm 4's server-side apply conflicts with the controller's edits to the Service selectors and HTTPRoute weights when the chart is upgraded with Helm by hand. Argo CD applies these apps client-side and ignores the weights, so GitOps is unaffected. Use `kubectl argo rollouts` and Git, not `helm upgrade`, for prod.
- Without traffic, a canary pauses at 10% (Inconclusive) instead of promoting. The canary demo (coming in the demos PR) runs k6 against prod while promoting. To ship a change with no traffic, promote by hand: `kubectl argo rollouts promote`.
