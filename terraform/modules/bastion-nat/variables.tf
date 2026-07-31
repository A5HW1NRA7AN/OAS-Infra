variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_id" { type = string }
variable "private_route_table_id" {
  description = "Private route table to receive the 0.0.0.0/0 -> bastion ENI default route."
  type        = string
}
variable "ami_id" { type = string }
variable "key_name" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "admin_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the bastion (lock to your admin/Jenkins IPs)."
  type        = list(string)
}
