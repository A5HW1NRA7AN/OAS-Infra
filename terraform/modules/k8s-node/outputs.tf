output "node_private_ip" {
  description = "Private IP of the K8s node (reached via the bastion; Kong NodePort lives here)."
  value       = aws_instance.k8s_node.private_ip
}

output "node_sg_id" {
  description = "Security group id of the K8s node (env adds the nginx->30080 rule to it)."
  value       = aws_security_group.k8s_node_sg.id
}

output "instance_id" {
  value = aws_instance.k8s_node.id
}
