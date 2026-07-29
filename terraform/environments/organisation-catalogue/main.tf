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

  aws_region   = var.aws_region
  cluster_name = "Organisation-Catalogue-Pilot"
  # Distinct key pair name — aws_key_pair names are unique per account/region,
  # so a second environment must NOT reuse the module default (oas-pilot-key-pair)
  # or it collides with the agri-catalogue environment.
  key_name             = "oas-org-pilot-key-pair"
  vpc_id               = aws_default_vpc.default.id
  subnet_id            = tolist(data.aws_subnets.default.ids)[0]
  instance_type        = var.instance_type
  root_volume_size     = var.root_volume_size
  allowed_ssh_cidrs    = var.allowed_ssh_cidrs
  allowed_kong_cidrs   = var.allowed_kong_cidrs
  iam_instance_profile = var.iam_instance_profile
}
