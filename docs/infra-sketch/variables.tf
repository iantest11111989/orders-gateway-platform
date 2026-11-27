variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "env" {
  description = "dev, staging or prod."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "kubernetes_version" {
  description = "The newest version EKS offers."
  type        = string
}
