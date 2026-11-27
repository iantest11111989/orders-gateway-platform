# Terraform sketch: the platform on EKS

**A sketch, never applied.** `terraform validate` passes, nothing more. It sketches what changes between the local kind cluster and a real cloud deployment: the shape and the choices, not a tested module. Monitoring moves to Datadog, as in [`../production.md`](../production.md). Datadog is a paid service; the local stack stays open source, as the brief requires.

What Terraform does here, and what it deliberately doesn't:

| Terraform owns | Argo CD keeps owning (unchanged from `stack/bootstrap/` and `stack/`) |
| --- | --- |
| VPC across 3 zones, private subnets, NAT | Every platform component: the AWS Load Balancer Controller, Kyverno, the Datadog Agent, ... |
| EKS: private API endpoint, SSO access entries, add-ons (VPC CNI with network policy) | The app in dev, staging and prod, from `apps/orders-gateway/cd/*.yaml` |
| Two node groups: `platform` (tainted) and `apps` | Promotion by Git change, self-heal and prune |
| IAM roles for service accounts: ExternalDNS, the AWS Load Balancer Controller, External Secrets | |
| Datadog: the SLOs and burn-rate monitors, and a Secrets Manager entry for the Agent's API key | |
| An ECR pull-through cache of GHCR | |
| Argo CD and the root Application, the only two things installed by hand today (`./platform up`) | |

The line between them matters: Terraform changes slowly and needs a plan reviewed; Argo CD reconciles every minute. Putting the app's Helm releases in Terraform would give two owners for the same objects.

How it maps to the local stack:

| Local (kind, `docker compose up`) | EKS (this sketch) |
| --- | --- |
| kind: 1 control plane + 2 workers, two fake zones | EKS's managed control plane, nodes in 3 real zones |
| One cluster, three namespaces | One cluster per environment (`env` is dev, staging or prod), each with its own Argo CD |
| Traefik on NodePorts mapped to `127.0.0.1`, plain HTTP | No Traefik: the AWS Load Balancer Controller makes an ALB (with WAF) per Ingress, sending traffic straight to the pods ([`../production.md`](../production.md#traffic-in-the-aws-load-balancer-controller-instead-of-traefik)) |
| No TLS, a port per environment | ACM certificates on the load balancer, which terminates TLS; ExternalDNS writing Route 53 |
| Sealed Secrets with a demo key in Git | External Secrets reading AWS Secrets Manager (`platform-demo/<env>/*`) |
| Prometheus (24 h), Loki, Grafana, alerts to a local receiver | The Datadog Agent on every node (metrics and logs), 30-day SLOs, pages to PagerDuty |
| In-stack Git server (soft-serve) | GitHub, with promotion PRs and approvals for prod |
| `./pipeline ci` publishes unsigned images to the in-stack registry (`localhost:30500`) | Only CI-built, signed images in ECR; nothing built on a laptop is admitted |
| `admin` / `admin12345` | SSO for Argo CD, Datadog and the cluster (access entries) |

Not here, and needed before this is real: remote state bootstrap (the S3 bucket itself), Karpenter or the cluster autoscaler, the Datadog Agent's values in `stack/`, and a `terraform plan` in CI with the plan posted on the PR.
