variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "system_node_instance_types" {
  type = list(string)
}

variable "system_node_min" {
  type = number
}

variable "system_node_max" {
  type = number
}

variable "system_node_desired" {
  type = number
}

variable "karpenter_namespace" {
  type = string
}