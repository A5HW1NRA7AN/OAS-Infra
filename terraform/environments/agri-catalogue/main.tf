terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Default VPC (ap-northeast-1) ──────────────────────────────────────────────

resource "aws_default_vpc" "default" {}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [aws_default_vpc.default.id]
  }
}

# ── K8s Node Module ──────────────────────────────────────────────────────────

module "k8s_node" {
  source = "../../modules/k8s-node"
  
  aws_region = var.aws_region
  cluster_name         = "Agri-Catalogue-Pilot"
  vpc_id               = aws_default_vpc.default.id
  subnet_id            = tolist(data.aws_subnets.default.ids)[0]
  instance_type        = "t3.xlarge"
  root_volume_size     = 150
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  allowed_kong_cidrs   = var.allowed_kong_cidrs
  iam_instance_profile = var.iam_instance_profile
}
