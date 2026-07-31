variable "cluster_name" {
  description = "Prefix name for the node's resources."
  type        = string
  default     = "oas-uat"
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Private app-tier subnet the node lands in."
  type        = string
}

variable "ami_id" {
  description = "Ubuntu 22.04 AMI id (provided by the environment)."
  type        = string
}

variable "key_name" {
  description = "Name of the shared EC2 key pair (created by the environment)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the K8s node."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB (OS, images, local-path PVs)."
  type        = number
  default     = 150
}

variable "bastion_sg_id" {
  description = "Bastion SG allowed to reach SSH (22) and the K8s API (6443)."
  type        = string
}

variable "iam_instance_profile" {
  description = "Instance profile granting ECR read (from the iam module)."
  type        = string
}
