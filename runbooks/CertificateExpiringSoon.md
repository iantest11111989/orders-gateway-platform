# CertificateExpiringSoon

**Severity: ticket.** The certificate still works, but it expires in under 14 days and cert-manager hasn't renewed it.

## What it means

cert-manager renews the gateway's `localtest-me` certificate 30 days before it expires (90-day lifetime), and the `ogp-demo-ca` CA at two thirds of its one-year life. Under 14 days left means renewal has been failing for weeks. When it expires, every `https://*.localtest.me` URL fails TLS.

The labels `exported_namespace` and `name` say which certificate.

## How to check and fix

The cause is the same as a certificate that isn't Ready, so follow [CertificateNotReady](CertificateNotReady.md): the Certificate's `Ready` condition, the latest CertificateRequest, the `ogp-demo-ca` ClusterIssuer, and cert-manager's logs. Once renewal works, the new expiry shows in `kubectl -n <namespace> get certificate <name> -o jsonpath='{.status.notAfter}'`, and the alert clears.
