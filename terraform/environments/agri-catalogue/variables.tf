variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks to allow SSH (TCP 22) inbound. Restrict to Admin/Jenkins IPs."
  type        = list(string)
  default     = ["0.0.0.0/0"] # TODO: Restrict this to Jenkins and Admin IP
}

variable "allowed_kong_cidrs" {
  description = "List of CIDR blocks to allow Kong Proxy (TCP 30080) inbound."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "iam_instance_profile" {
  description = "IAM Instance Profile to attach to the EC2 for ECR read access"
  type        = string
  default     = "EC2-ECR-Read-Role"
}
