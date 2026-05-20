variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string
}

variable "cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of AZs to create subnets in"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}