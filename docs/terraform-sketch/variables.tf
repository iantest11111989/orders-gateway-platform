variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "env" {
  description = "prod gets its own cluster; dev and staging share one."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "The newest EKS offers; kind runs v1.37.0 (cluster/kind.yaml), and EKS trails upstream."
  type        = string
}

variable "platform_admin_role_arn" { type = string }
variable "route53_zone_arn" { type = string }
variable "ghcr_credential_arn" { type = string }

variable "repo_url" {
  type    = string
  default = "https://github.com/iantest11111989/orders-gateway-platform.git"
}

variable "argocd_apps_chart_version" { type = string }
