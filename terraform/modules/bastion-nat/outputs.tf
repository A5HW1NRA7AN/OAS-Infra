output "public_ip" {
  description = "Bastion public IP (SSH entry + ProxyJump host). Auto-assigned (no EIP)."
  value       = aws_instance.bastion.public_ip
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
