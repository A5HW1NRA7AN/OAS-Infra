variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_id" { type = string }
variable "ami_id" { type = string }
variable "key_name" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "bastion_sg_id" {
  description = "Bastion SG allowed to SSH into nginx."
  type        = string
}
variable "kong_upstream_host" {
  description = "Private IP of the k8s node running Kong's NodePort."
  type        = string
}
variable "kong_upstream_port" {
  type    = number
  default = 30080
}
