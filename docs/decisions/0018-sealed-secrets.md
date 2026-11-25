# 0018: Sealed Secrets with a committed demo key; no plain Secrets in Git

**Status:** Accepted, 2026-11-24

## Context

Decision 0002 chose Sealed Secrets with a committed demo key: the whole stack has to come up from `git clone` and `./platform up` on any laptop and in CI, with no vault to set up first. Until now Grafana's admin login was the chart's fixed default (`admin` / `prom-operator`), in plain text in the values. Nothing stopped a plain Secret from being committed.

## Choices

- **Controller:** chart `sealed-secrets` 2.22.0 (controller v0.41.2, the same version as `kubeseal` in the toolbox), wave 10, in `kube-system` as `sealed-secrets-controller`. That's where kubeseal looks by default, so it needs no flags. A Renovate group keeps the chart and kubeseal together. Requests are 10m / 32Mi, with a 128Mi limit and a ServiceMonitor.
- **DEMO ONLY key, committed:** `gitops/manifests/sealed-secrets/demo-key.yaml` (an RSA-4096 TLS Secret labelled `sealedsecrets.bitnami.com/sealed-secrets-key: active`), plus its public certificate `demo-cert.pem`.
  - `./platform up` applies the key before Argo CD starts, and the Application has it at sync wave -1, so the controller finds it on first start and never generates its own.
  - `keyrenewperiod: "0"` turns off the 30-day key renewal. The committed key then stays the only one, and the active certificate never drifts from `demo-cert.pem`.
- **Sealing is offline:** `scripts/seal.sh <namespace> <name> key=value…` seals with `demo-cert.pem`, so no cluster is needed and any fresh cluster can unseal the result.
- **Grafana's admin login** is now a SealedSecret, `gitops/manifests/monitoring/grafana-admin.sealed.yaml`, with a random password. The `kube-prometheus-stack` Application applies it as an extra source, and Grafana reads it through `admin.existingSecret`. `./platform urls` prints the password.
- **No plain Secrets or private keys in Git:** `scripts/check-no-plain-secrets.sh` runs in its own workflow (`secrets.yml`) on every PR, with no path filter. It fails on any tracked YAML/JSON document of `kind: Secret` and on any PEM private key. The only path it allows is the demo key file. `.gitignore` still ignores `*.key` and `*.pem`, except the public demo certificate.

## DEMO ONLY: what this does not protect

The private key is in the repo, so anyone who can read the repo can unseal every SealedSecret in it. These SealedSecrets show the workflow; they don't keep anything secret. Never seal a real credential with this key. In a real deployment:
- the key is generated in the cluster and backed up offline, never committed; or
- secrets come from a vault through External Secrets (the alternative in decision 0002).

## Re-sealing and rotating

- **Changing a value:** run `scripts/seal.sh` again and commit the output. Argo CD applies it and the controller updates the Secret. Pods that read it at start-up, like Grafana, need a restart.
- **Rotating the demo key:** generate a new key pair, replace `demo-key.yaml` and `demo-cert.pem`, re-seal every SealedSecret, and recreate the cluster (or delete the old key Secret and restart the controller). Old SealedSecrets don't decrypt with a new key.

## Tests

- The Grafana SealedSecret unseals offline with the committed private key (`kubeseal --recovery-unseal`).
- `check-no-plain-secrets.sh` passes on the branch and fails on a test plain Secret and a test PEM key.
- shellcheck, actionlint and `renovate-config-validator --strict` are clean. The apps chart renders 19 Applications.
- This PR's CI does a fresh `./platform up`: Grafana only becomes Healthy if the controller has unsealed its login with the demo key.
