variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "name_prefix" {
  description = "Prefix for all resource names/tags."
  type        = string
  default     = "oas-uat"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Two AZs for subnet spread (instances live in azs[0] for now)."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "admin_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the bastion. LOCK THIS DOWN to your admin/Jenkins IPs in terraform.tfvars."
  type        = list(string)
  default     = ["0.0.0.0/0"] # TODO: restrict in terraform.tfvars
}

variable "ecr_instance_profile" {
  description = "Pre-existing EC2 instance profile (name) granting ECR read for the k8s node. Managed outside this repo."
  type        = string
  default     = "EC2-ECR-Read-Role"
}

variable "db_host_private_ip" {
  description = "Fixed private IP for the DB host (must be inside data subnet azs[0], i.e. 10.0.10.0/24)."
  type        = string
  default     = "10.0.10.10"
}

# ── Instance sizing ──────────────────────────────────────────────────────────
variable "bastion_instance_type" {
  type    = string
  default = "t3.small"
}
variable "nginx_instance_type" {
  type    = string
  default = "t3.small"
}
variable "k8s_instance_type" {
  type    = string
  default = "t3.xlarge"
}
variable "k8s_root_volume_size" {
  type    = number
  default = 150
}
variable "db_instance_type" {
  type    = string
  default = "t3.xlarge"
}
variable "db_root_volume_size" {
  type    = number
  default = 100
}
