output "cluster_id" {
  value = aws_eks_cluster.sathya.id
}

output "node_group_id" {
  value = aws_eks_node_group.sathya.id
}

output "vpc_id" {
  value = aws_vpc.sathya_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.sathya_subnet[*].id
}
