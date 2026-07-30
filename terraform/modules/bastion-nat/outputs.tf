output "public_ip" {
  description = "Bastion Elastic IP (SSH entry + ProxyJump host)."
  value       = aws_eip.bastion.public_ip
}

output "private_ip" {
  value = aws_instance.bastion.private_ip
}

output "security_group_id" {
  value = aws_security_group.bastion.id
}

output "instance_id" {
  value = aws_instance.bastion.id
}
