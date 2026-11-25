# 0022: Enforce the tag and signature policies in the orders namespaces

**Status:** Accepted, 2026-11-25

## Context

Decision 0012 started every Kyverno policy in Audit, to move each one to Enforce in its own PR once its failures stay at zero. The brief's definition of done asks for Kyverno *rejecting* bad manifests, and the `policy` demo (section 11) needs an unsigned image and a `:latest` image to be refused, not just reported.

Until 2026-11-25, staging and prod ran `sha-85cbba12fef7` (`sha256:09c2177c…`), built before image signing existed (decision 0013), so enforcing the signature policy would have rejected the next prod pod. Promotions #51 (staging) and #52 (prod) moved both to the signed `sha-d5d3d8f966ab` first (`cosign verify` checked both digests).

## Choices

- **`disallow-latest-tag`: Deny, in `orders-*` only** (`matchConditions: request.namespace.startsWith('orders-')`). The app's own pods have always passed. A copy, **`disallow-latest-tag-platform`**, keeps the same checks in Audit for every other namespace, so third-party charts are reported, not blocked. A CEL policy has one `validationActions`, so a split is the only way to have both. The two files carry a "keep in step" comment.
- **`verify-image-signatures`: Deny.** It only matches `ghcr.io/iantest11111989/orders-gateway*`, which only runs in `orders-*`, so it needs no namespace condition. Every image the environments and demos use (dev's, staging's, prod's, and the demo `v1`, `v2`, `v2-bad`) is signed by the app workflow on main.
- **`failurePolicy` stays `Ignore`.** Kyverno runs one admission replica to fit the budget. With `Fail`, every orders pod (scale-ups, canary steps, rescheduled pods) would be refused while Kyverno restarts. With `Ignore`, a Kyverno outage lets pods through unchecked. Kyverno checks again only on the next pod creation once it answers. That's the right trade for a demo cluster with a single Kyverno replica. Production would run three Kyverno replicas with `Fail`.
- **`./platform verify` now checks a rejection,** not an audit count: a server-side dry run of a `:latest` pod in `orders-dev` must be denied, with `disallow-latest-tag` named in the error. A dry run creates nothing.
- **The other policies stay in Audit** for now. They move the same way, one PR each.

## Consequences

- A `:latest` or untagged image, or an orders-gateway image not signed by main's app workflow, can't start in `orders-dev`, `orders-staging`, `orders-prod` or `orders-demo`.
- Signature checks need GHCR and Sigstore's trust root to be reachable when a pod is created. If they aren't, verification errors and the pod is refused until they are. The ReplicaSet or Rollout retries, and running pods are unaffected.
- A pod created while Kyverno is down is admitted unchecked and **stays running**. Nothing re-checks it, because the background controller is off. Only later pod creations are rejected.
- A new environment must be named `orders-*` to be covered.
- `orders-*` namespaces enforce Pod Security `restricted`, which the API server checks before Kyverno's webhook. A pod that breaks both is refused by Pod Security, without naming the Kyverno policy. `./platform verify`'s test pod meets `restricted` for that reason.

## Tests

- `kyverno test policies/tests`: 33 cases. These include `platform-latest` (a `:latest` pod in `monitoring`), which the platform policy fails and the orders policy skips, and the existing orders-dev cases for the Deny policy.
- `./platform verify` in CI's full `up` job, on this branch, checks the rejection end to end.
