

output "node_public_ip" {
  description = "The Public IP of the Kubernetes Node (Kong Entrypoint)"
  value       = aws_instance.k8s_node.public_ip
}

output "node_private_ip" {
  description = "The private IP of the Kubernetes Node"
  value       = aws_instance.k8s_node.private_ip
}

output "ssh_connection_string" {
  description = "SSH command to connect to the node"
  value       = "ssh -i ./oas-key.pem ubuntu@${aws_instance.k8s_node.public_ip}"
}


