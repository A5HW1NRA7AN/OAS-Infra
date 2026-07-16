variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "EC2 instance type for the single K8s node. Bump to t3.2xlarge (or larger) if the application/data services need more headroom. Override with TF_VAR_instance_type or a *.tfvars file."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB (holds OS, images, and all local-path PVs)."
  type        = number
  default     = 150
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
