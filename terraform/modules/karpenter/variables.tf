variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "karpenter_namespace" {
  type = string
}

variable "karpenter_version" {
  type = string
}

variable "karpenter_node_role_arn" {
  type = string
}

variable "karpenter_node_role_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "cluster_security_group_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "account_id" {
  type = string
}

variable "aws_region" {
  type = string
}