data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source = "./modules/vpc"

  name               = var.cluster_name
  cidr               = var.vpc_cidr
  availability_zones = local.azs
  cluster_name       = var.cluster_name
}

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  system_node_instance_types = var.system_node_instance_types
  system_node_min            = var.system_node_min
  system_node_max            = var.system_node_max
  system_node_desired        = var.system_node_desired

  karpenter_namespace = var.karpenter_namespace
}

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name              = var.cluster_name
  cluster_endpoint          = module.eks.cluster_endpoint
  kubernetes_version        = var.kubernetes_version
  karpenter_namespace       = var.karpenter_namespace
  karpenter_version         = var.karpenter_version
  karpenter_node_role_arn   = module.eks.karpenter_node_role_arn
  karpenter_node_role_name  = module.eks.karpenter_node_role_name
  private_subnet_ids        = module.vpc.private_subnet_ids
  cluster_security_group_id = module.eks.cluster_security_group_id
  account_id                = local.account_id
  aws_region                = var.aws_region
  oidc_provider_arn         = module.eks.oidc_provider_arn
  oidc_provider_url         = module.eks.oidc_provider_url

  depends_on = [module.eks]
}