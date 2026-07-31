output "public_ip" {
  description = "nginx public IP — the public base URL for the APIs (http://<this>/...). Auto-assigned (no EIP)."
  value       = aws_instance.nginx.public_ip
}

output "security_group_id" {
  value = aws_security_group.nginx.id
}

output "instance_id" {
  value = aws_instance.nginx.id
}
