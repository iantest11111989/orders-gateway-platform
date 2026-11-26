# 0013: Keyless cosign signatures and BuildKit SBOMs for the app image

**Status:** Accepted, 2026-11-24

## Context

The brief (section 9.3) asks for signed images with an SBOM, which a Kyverno policy can verify at admission (ADR 0012). The app image is the only image this repo builds. It's published from main by `.github/workflows/app.yml` as `sha-<commit>`/`main`, plus the demo tags `v1`, `v2` and `v2-bad`, which are rebuilt and re-pushed from every main commit.

## Choices

- **Keyless signing (Sigstore).** A separate `sign` job, after `publish`, gets a GitHub OIDC token and Fulcio issues a short-lived certificate for it. There's no key to store or rotate. The certificate records the workflow and ref (`.../.github/workflows/app.yml@refs/heads/main`), so a verifier can require "built by this workflow on main". Only `sign` has `id-token: write`; the workflow's default stays read-only.
- **Sign by digest, not tag.** The demo tags move on every main commit, so a signature on a tag would describe whatever the tag pointed at when it was signed. Signatures attach to the index digests that `publish` outputs. Prod pins `image.digest`, so admission can match exactly what was signed.
- **SBOMs from BuildKit (`sbom: true`), not a separate attestation.** BuildKit scans each platform's image and stores an SPDX SBOM in the image index. The cosign signature covers the index digest, and the index lists the SBOM manifests by digest, so the SBOMs are covered by the same signature. A separate `cosign attest` per platform would mean more moving parts for the same guarantee.
- **The job checks its own output.** After signing, it runs `cosign verify` with the exact certificate identity and issuer, and requires a non-empty SBOM for linux/amd64 and linux/arm64. A main build therefore fails if anything a later admission policy relies on is missing.
- **Pull requests rehearse it.** `scripts/sign-images.sh` holds the sign/verify/SBOM steps, and both jobs call it. On a pull request, the image job pushes to a throwaway `registry` service on localhost (nothing public) and runs the same script with that PR's identity (`...@refs/pull/<n>/merge`). A broken signing step therefore fails the PR, not main. The rehearsal signatures land in the public Rekor log, like main's. Fork PRs get no OIDC token, so they skip the rehearsal. `scripts/sign-images.sh` is in the workflow's path filters, so a change to the script alone still runs the rehearsal.

## Consequences

- cosign v3 stores each signature as a Sigstore bundle, attached to the image digest as an OCI 1.1 referring artifact in the same GHCR package, not as the older `sha256-<digest>.sig` tag. Kyverno 1.20's ImageValidatingPolicy finds these bundles; its v1.20.0 source looks up the image's referrers and loads them. The SBOMs are attestation manifests inside each image index. Every main commit adds four signatures, and nothing prunes them yet.
- Pull requests build but don't publish, so they're never signed. Only reviewed code on main gets a signature.
- Next: a Kyverno image-verification policy for `ghcr.io/iantest11111989/orders-gateway`, in Audit first like the others, checking the identity above.
- **If `sign` fails on main,** the images are already published but unsigned. Re-run the failed job from the Actions tab: it signs the same digests, which are job outputs of `publish`. Don't promote an unsigned digest to staging or prod. Once the verify policy enforces, it would reject one anyway.
- Locally, a multi-arch `--sbom=true` build to a scratch registry gave 18 SPDX packages per platform with the same `imagetools inspect` check that CI uses.

## Useful commands

```sh
cosign verify ghcr.io/iantest11111989/orders-gateway@sha256:<digest> \
  --certificate-identity-regexp '^https://github\.com/iantest11111989/orders-gateway-platform/\.github/workflows/(cd-app|app)\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
docker buildx imagetools inspect ghcr.io/iantest11111989/orders-gateway@sha256:<digest> --format '{{ json .SBOM }}'
```

## Addendum, 2026-11-25: the CI/CD split

The app workflow split into `ci-app.yml` (pull requests) and `cd-app.yml` (merges to `main`), so signing now runs in `cd-app.yml` and the certificate identity names that file. `verify-image-signatures` accepts either file name with `subjectRegExp` (one identity entry; a second entry would also have to match), so images signed before the split, by `app.yml`, still verify.
