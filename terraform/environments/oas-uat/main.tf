# oas-uat — the single environment composing the whole OAS platform:
#   network (VPC + subnets) → iam → bastion/NAT → k8s node → nginx → db host.
# State is LOCAL and gitignored. One shared SSH key pair is generated here and
# used by every instance (bastion, k8s node, nginx, db host).

terraform {
  required_providers {
    aws   = { source = "hashicorp/aws", version = ">= 5.0" }
    tls   = { source = "hashicorp/tls", version = ">= 4.0" }
    local = { source = "hashicorp/local", version = ">= 2.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Shared AMI (Ubuntu 22.04) ────────────────────────────────────────────────
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Shared SSH key pair (generated; private key written locally, gitignored) ──
resource "tls_private_key" "oas" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "oas" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.oas.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.oas.private_key_pem
  filename        = "${path.module}/oas-key.pem"
  file_permission = "0400"
}

# ── Tiers ─────────────────────────────────────────────────────────────────────
module "network" {
  source      = "../../modules/network"
  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
  azs         = var.azs
}

# NOTE: IAM roles are managed OUT of this repo (the deploy IAM user cannot manage
# IAM). We reuse the pre-existing instance profile `EC2-ECR-Read-Role` for ECR
# pulls (var.ecr_instance_profile).

module "bastion_nat" {
  source                 = "../../modules/bastion-nat"
  name_prefix            = var.name_prefix
  vpc_id                 = module.network.vpc_id
  vpc_cidr               = module.network.vpc_cidr
  public_subnet_id       = module.network.public_subnet_ids[0]
  private_route_table_id = module.network.private_route_table_id
  ami_id                 = data.aws_ami.ubuntu_22_04.id
  key_name               = aws_key_pair.oas.key_name
  instance_type          = var.bastion_instance_type
  admin_ssh_cidrs        = var.admin_ssh_cidrs
}

module "k8s_node" {
  source               = "../../modules/k8s-node"
  cluster_name         = var.name_prefix
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.app_subnet_ids[0]
  ami_id               = data.aws_ami.ubuntu_22_04.id
  key_name             = aws_key_pair.oas.key_name
  instance_type        = var.k8s_instance_type
  root_volume_size     = var.k8s_root_volume_size
  bastion_sg_id        = module.bastion_nat.security_group_id
  iam_instance_profile = var.ecr_instance_profile
}

# Kong's NodePort (30080) on the k8s node, reachable ONLY from the nginx tier.
# Defined here (not in the k8s-node module) to avoid a k8s-node<->nginx cycle.
resource "aws_security_group_rule" "k8s_kong_from_nginx" {
  type                     = "ingress"
  description              = "Kong NodePort from nginx"
  from_port                = 30080
  to_port                  = 30080
  protocol                 = "tcp"
  security_group_id        = module.k8s_node.node_sg_id
  source_security_group_id = module.nginx.security_group_id
}

module "nginx" {
  source             = "../../modules/nginx"
  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  public_subnet_id   = module.network.public_subnet_ids[0]
  ami_id             = data.aws_ami.ubuntu_22_04.id
  key_name           = aws_key_pair.oas.key_name
  instance_type      = var.nginx_instance_type
  bastion_sg_id      = module.bastion_nat.security_group_id
  kong_upstream_host = module.k8s_node.node_private_ip
}

module "db_host" {
  source           = "../../modules/db-host"
  name_prefix      = var.name_prefix
  vpc_id           = module.network.vpc_id
  data_subnet_id   = module.network.data_subnet_ids[0]
  private_ip       = var.db_host_private_ip
  ami_id           = data.aws_ami.ubuntu_22_04.id
  key_name         = aws_key_pair.oas.key_name
  instance_type    = var.db_instance_type
  root_volume_size = var.db_root_volume_size
  k8s_node_sg_id   = module.k8s_node.node_sg_id
  bastion_sg_id    = module.bastion_nat.security_group_id
}
