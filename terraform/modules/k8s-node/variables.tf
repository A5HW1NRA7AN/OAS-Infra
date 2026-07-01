variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_id" {
  description = "VPC ID where the node will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the node will be deployed"
  type        = string
}

variable "cluster_name" {
  description = "Prefix name for the resources"
  type        = string
  default     = "OAS-Pilot"
}

variable "instance_type" {
  description = "EC2 instance type for the Kubernetes Node"
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 150
}

variable "key_name" {
  description = "Name for the auto-generated SSH key pair"
  type        = string
  default     = "oas-pilot-key-pair"
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
