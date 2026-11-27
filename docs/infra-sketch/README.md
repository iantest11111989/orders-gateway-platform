# Infrastructure sketch

**A sketch, never applied.** `terraform validate` passes, nothing more.

The cloud infrastructure one environment needs, in Terraform. Each environment (dev, staging, prod) gets its own copy, in its own AWS account.

| | What | Why |
| --- | --- | --- |
| Network | A VPC across 3 availability zones: a private and a public subnet in each, a NAT gateway per zone | Losing a zone doesn't take the app down. Nodes stay private; only the load balancer is public |
| Cluster | EKS: a managed Kubernetes control plane, its API reachable only inside the VPC | Replaces the local kind cluster |
| Nodes | One managed node group, 3 to 9 nodes across the zones | Room for the HPA to scale |

Everything inside the cluster (Argo CD, the platform components and the app) is installed the way it is today, through Argo CD from Git. Terraform stops at the cluster.

See [`../production.md`](../production.md) for what else changes in production.
