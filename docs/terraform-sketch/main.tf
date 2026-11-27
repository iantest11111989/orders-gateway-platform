# A SKETCH, never applied: what `docker compose up` would become on EKS.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    helm   = { source = "hashicorp/helm", version = "~> 3.0" }
  }
  # One state per cluster.
  backend "s3" {
    bucket       = "platform-demo-terraform-state"
    key          = "clusters/prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { project = "platform-demo", env = var.env } }
}

data "aws_availability_zones" "available" { state = "available" }
locals { azs = slice(data.aws_availability_zones.available.names, 0, 3) }

# Three real zones; nodes in private subnets, public ones only for the LB.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = "platform-demo-${var.env}"
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = var.env == "prod" # one shared NAT outside prod, to save cost

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
}

# Replaces kind; the API server is private.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "platform-demo-${var.env}"
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  endpoint_public_access = false
  enable_irsa            = true # pod identities for the controllers below

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
    # Platform components (Argo CD, Prometheus, Loki, Kyverno...).
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
    # The app; Karpenter or the cluster autoscaler adds nodes past the HPA.
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

# IRSA for ExternalDNS, the AWS Load Balancer Controller and External Secrets.
# No cert-manager: ACM certificates on the load balancer.
module "irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version  = "~> 6.0"
  for_each = {
    external-dns     = { namespace = "external-dns", sa = "external-dns", attach = "external_dns" }
    aws-lb           = { namespace = "kube-system", sa = "aws-load-balancer-controller", attach = "load_balancer_controller" }
    external-secrets = { namespace = "external-secrets", sa = "external-secrets", attach = "external_secrets" }
  }

  name = "platform-demo-${var.env}-${each.key}"
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.namespace}:${each.value.sa}"]
    }
  }

  attach_external_dns_policy              = each.value.attach == "external_dns"
  external_dns_hosted_zone_arns           = [var.route53_zone_arn]
  attach_load_balancer_controller_policy  = each.value.attach == "load_balancer_controller"
  attach_external_secrets_policy          = each.value.attach == "external_secrets"
  external_secrets_secrets_manager_arns   = ["arn:aws:secretsmanager:${var.region}:*:secret:platform-demo/${var.env}/*"]
}

# ECR pull-through cache of GHCR, so a GHCR outage doesn't stop a scale-up.
resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"
  credential_arn        = var.ghcr_credential_arn
}

# Terraform stops at Argo CD and the root Application; everything else stays
# in stack/bootstrap/ and stack/ as in kind.
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
  version          = "10.18.2" # the same pin as stack/bootstrap/apps/templates/argocd.yaml
  namespace        = "argocd"
  create_namespace = true
  values           = [file("${path.module}/../../stack/argocd/values.yaml")]
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
          path           = "stack/bootstrap/apps"
          # A real port would add EKS values (load balancer, storage classes).
          helm = { valuesObject = { repo = { url = var.repo_url, revision = "main" } } }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
