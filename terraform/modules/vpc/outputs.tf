output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (used by nodes and pods)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets (used by NAT gateways and internet-facing load balancers)"
  value       = aws_subnet.public[*].id
}