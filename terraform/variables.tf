variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and associated resources"
  type        = string
  default     = "startup-eks"
}

variable "environment" {
  description = "Environment label applied to all resources"
  type        = string
  default     = "production"
}

variable "kubernetes_version" {
  description = "Kubernetes version to use for the EKS control plane"
  type        = string
  default     = "1.36.1"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to spread subnets across. Defaults to first three in the region"
  type        = list(string)
  default     = []
}

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group (runs kube-system and Karpenter)"
  type        = list(string)
  default     = ["m7g.medium", "m6g.medium"]
}

variable "system_node_min" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 4
}

variable "system_node_desired" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "karpenter_version" {
  description = "Version of the Karpenter Helm chart to deploy"
  type        = string
  default     = "1.12.1"
}

variable "karpenter_namespace" {
  description = "Kubernetes namespace for Karpenter"
  type        = string
  default     = "karpenter"
}