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

- **Issuer not Ready** (`ErrGetKeyPair`, `ErrInitIssuer`): the demo CA's secret `cert-manager/ogp-demo-ca` is missing or invalid. Deleting the `ogp-demo-ca` Certificate's secret makes cert-manager issue a new CA (**destructive: ask the owner first**). Then re-trust it in your browser (`./platform urls`).
- **Request waiting for approval:** cert-manager's approver is down; check its pods in `cert-manager`.
- After a fix, cert-manager retries on its own. To force a new certificate at once, delete the certificate's secret (`kubectl -n <namespace> delete secret <secretName>`, the name is in the Certificate's `spec.secretName`). **That's destructive: ask the owner first.** (The toolbox has no `cmctl` or cert-manager kubectl plugin.)

In production the issuer would be a public CA (ACME) or the company PKI; see the README's production differences.
