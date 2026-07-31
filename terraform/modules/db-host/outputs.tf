output "private_ip" {
  description = "Fixed private IP of the DB host (used in app SPRING_DATASOURCE_URL / ELASTICSEARCH_HOST / SPRING_REDIS_HOST)."
  value       = aws_instance.db_host.private_ip
}

output "security_group_id" {
  value = aws_security_group.db_host.id
}

output "instance_id" {
  value = aws_instance.db_host.id
}
