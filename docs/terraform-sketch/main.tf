# A SKETCH, never applied: what `docker compose up` would become on AWS (EKS).
# It shows the shape and the choices, not a tested module. See README.md here.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    helm   = { source = "hashicorp/helm", version = "~> 3.0" }
  }
  # State in S3 with locking, one state per cluster (prod apart from the rest).
  backend "s3" {
    bucket       = "ogp-terraform-state"
    key          = "clusters/prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { project = "orders-gateway-platform", env = var.env } }
}

data "aws_availability_zones" "available" { state = "available" }
locals { azs = slice(data.aws_availability_zones.available.names, 0, 3) }

# Network: three zones (kind's two "zones" become real ones), private
# subnets for nodes, public ones only for the load balancer.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = "ogp-${var.env}"
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = var.env == "prod" # one shared NAT outside prod, to save cost

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
}

# The cluster. Replaces kind; the API server is private, reached through
# the VPN or SSO, never 127.0.0.1.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "ogp-${var.env}"
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  endpoint_public_access = false
  enable_irsa            = true # pod identities for the controllers below

  # Who may administer the cluster: an SSO role, not a shared admin.
  access_entries = {
    platform = {
      principal_arn = var.platform_admin_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    vpc-cni                = {} # with network policy enforcement on
    coredns                = {}
    kube-proxy             = {}
    aws-ebs-csi-driver     = {} # Prometheus, Loki and Grafana get real volumes
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    # Platform components (Argo CD, Prometheus, Loki, Kyverno...): kind's
    # control-plane node did this job.
    platform = {
      instance_types = ["m7g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 3
      max_size       = 4
      desired_size   = 3
      labels         = { role = "platform" }
      taints = {
        platform = { key = "role", value = "platform", effect = "NO_SCHEDULE" }
      }
    }
    # The app. The HPA (3-6 pods) works inside these; Karpenter or the
    # cluster autoscaler adds nodes when it runs out.
    apps = {
      instance_types = ["m7g.large", "m6g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 3
      max_size       = 9
      desired_size   = 3
      labels         = { role = "apps" }
    }
  }
}

# Pod identities for the controllers that need AWS: certificates from a
# public CA through DNS-01 (cert-manager), DNS records (ExternalDNS), the
# load balancer (AWS Load Balancer Controller), secrets (External Secrets).
module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version  = "~> 6.0"
  for_each = {
    cert-manager     = { namespace = "cert-manager", sa = "cert-manager", attach = "cert_manager" }
    external-dns     = { namespace = "external-dns", sa = "external-dns", attach = "external_dns" }
    aws-lb           = { namespace = "kube-system", sa = "aws-load-balancer-controller", attach = "load_balancer_controller" }
    external-secrets = { namespace = "external-secrets", sa = "external-secrets", attach = "external_secrets" }
  }

  name = "ogp-${var.env}-${each.key}"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.namespace}:${each.value.sa}"]
    }
  }

  attach_cert_manager_policy              = each.value.attach == "cert_manager"
  cert_manager_hosted_zone_arns           = [var.route53_zone_arn]
  attach_external_dns_policy              = each.value.attach == "external_dns"
  external_dns_hosted_zone_arns           = [var.route53_zone_arn]
  attach_load_balancer_controller_policy  = each.value.attach == "load_balancer_controller"
  attach_external_secrets_policy          = each.value.attach == "external_secrets"
  external_secrets_secrets_manager_arns   = ["arn:aws:secretsmanager:${var.region}:*:secret:ogp/${var.env}/*"]
}

# Images: the same signed images CI pushes to GHCR today, mirrored to ECR
# (pull-through cache) so a GHCR outage doesn't stop a scale-up.
resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"
  credential_arn        = var.ghcr_credential_arn
}

# Terraform's job ends where Argo CD's begins: install Argo CD and hand it
# the same root Application `./platform up` uses, pointed at GitHub. Every
# other component stays in gitops/, exactly as it is in kind.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.2" # the same pin as gitops/apps/templates/argocd.yaml
  namespace        = "argocd"
  create_namespace = true
  values           = [file("${path.module}/../../gitops/values/argocd.yaml")]
}

resource "helm_release" "root" {
  name       = "root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"
  depends_on = [helm_release.argocd]
  values = [yamlencode({
    applications = {
      root = {
        project = "default"
        source = {
          repoURL        = var.repo_url
          targetRevision = "main"
          path           = "gitops/apps"
          # Today's values; a real port adds an EKS layer (gitops/values/*-eks.yaml)
          # for the load balancer, storage classes and cert-manager's issuer.
          helm = { valuesObject = { repo = { url = var.repo_url, revision = "main" } } }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
