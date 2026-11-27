# A sketch, never applied: the cloud infrastructure one environment needs.
# One copy per environment (dev, staging, prod), each in its own AWS account.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "platform-demo-terraform-state"
    key          = "prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = { project = "platform-demo", env = var.env } }
}

data "aws_availability_zones" "available" { state = "available" }

locals {
  name = "platform-demo-${var.env}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
}

# Network: a VPC across 3 zones. Nodes in private subnets; public subnets
# only for the load balancer and the NAT gateways.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = local.name
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  # So the AWS Load Balancer Controller knows where to put load balancers.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# The Kubernetes cluster: a managed control plane and one node group
# spread over the 3 private subnets.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  endpoint_public_access                   = false
  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni    = {}
    coredns    = {}
    kube-proxy = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = ["m7g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 3
      max_size       = 9
      desired_size   = 3
    }
  }
}
