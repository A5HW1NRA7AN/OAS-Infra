output "instance_profile_name" {
  value = aws_iam_instance_profile.ecr_read.name
}

output "role_arn" {
  value = aws_iam_role.ecr_read.arn
}
