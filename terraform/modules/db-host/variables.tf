variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "data_subnet_id" { type = string }
variable "private_ip" {
  description = "Fixed private IP within the data subnet (e.g. 10.0.10.10) so app config is stable."
  type        = string
}
variable "ami_id" { type = string }
variable "key_name" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.xlarge"
}
variable "root_volume_size" {
  description = "GB for the DB data volume (Postgres/ES/Redis persist here)."
  type        = number
  default     = 100
}
variable "k8s_node_sg_id" {
  description = "SG of the k8s nodes allowed to reach the DB ports."
  type        = string
}
variable "bastion_sg_id" {
  description = "Bastion SG allowed SSH + admin-GUI access (GUIs reached via SSH tunnel)."
  type        = string
}
