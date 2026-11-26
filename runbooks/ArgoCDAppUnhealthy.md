# ArgoCDAppUnhealthy

**Severity: ticket.** Something an Argo CD Application deployed is failing.

## What it means

An Application has been **Degraded** or **Missing** for 10 minutes. The `name` and `health_status` labels say which, and how.

- **Degraded:** a resource it owns reports a failure: a Deployment that can't make its pods ready, pods crash-looping, a certificate that isn't issued.
- **Missing:** a resource in Git doesn't exist in the cluster, usually because it was refused when Argo CD applied it.

If it's `dev`, `staging` or `prod`, the SLO alerts will page on their own if users are affected. This alert catches the cases that don't (yet) hurt traffic.

## How to check

```sh
./platform shell
argocd app get <name>                                   # which resource is Degraded or Missing, and why
kubectl -n <namespace> get pods                         # Ready? restarts?
kubectl -n <namespace> describe pod <pod>               # image pulls, probes, OOMKilled
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20
```

In the Argo CD UI, the resource tree marks the unhealthy resource with a red heart.

## Fix

Follow the failing resource: fix the image, config or limits in Git; for a certificate, see [CertificateNotReady](CertificateNotReady.md). `./platform budget` shows any `OOMKilled` containers.
