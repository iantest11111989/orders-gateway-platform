# CertificateNotReady

**Severity: ticket.** HTTPS still works until the current certificate expires, but renewal is failing.

## What it means

cert-manager couldn't issue or renew a Certificate ([decision 0008](../docs/decisions/0008-gateway-and-tls.md)):
- **CertificateNotReady:** its `Ready` condition has been False for 10 minutes.
- **CertificateExpiringSoon** (its own runbook, [CertificateExpiringSoon](CertificateExpiringSoon.md)): under 14 days left, so renewal has been failing.

The labels `exported_namespace` and `name` say which certificate.

## How to check

```sh
./platform shell
kubectl -n <namespace> get certificate <name>
kubectl -n <namespace> describe certificate <name>          # the Ready condition's reason and message
kubectl -n <namespace> get certificaterequests              # the latest request: Approved? Ready?
kubectl get clusterissuer ogp-demo-ca -o wide               # the issuer must be Ready
kubectl -n cert-manager logs deploy/cert-manager --tail=50
```

## Fix

- **Issuer not Ready** (`ErrGetKeyPair`, `ErrInitIssuer`): the demo CA's secret `cert-manager/ogp-demo-ca` is missing or invalid. Deleting the `ogp-demo-ca` Certificate's secret makes cert-manager issue a new CA. Then re-trust it in your browser (`./platform urls`).
- **Request waiting for approval:** cert-manager's approver is down; check its pods in `cert-manager`.
- After a fix, `kubectl cert-manager renew -n <namespace> <name>` (in the toolbox) or deleting the certificate's secret forces a new one.

In production the issuer would be a public CA (ACME) or the company PKI; see the README's production differences.
