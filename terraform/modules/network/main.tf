# network module — the OAS VPC and its subnets/routing.
#
# Topology (single-AZ instances now, but subnets span 2 AZs so scale-out is a
# later config change, not a re-architecture):
#   public : bastion(+NAT) and nginx  -> route via Internet Gateway
#   app    : Kubespray k8s node(s)     -> egress via the bastion NAT instance
#   data   : DB host (docker-compose)  -> egress via the bastion NAT instance
#
# This module does NOT create the private default route (0.0.0.0/0 -> bastion
# ENI); that lives in the bastion-nat module to avoid a network<->bastion cycle.
# It only exposes the private route-table id for that module to populate.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

locals {
  # Fixed subnet layout keyed by tier + AZ index.
  public_cidrs = var.public_subnet_cidrs # [a, b]
  app_cidrs    = var.app_subnet_cidrs
  data_cidrs   = var.data_subnet_cidrs
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ── Subnets (2 AZs each tier) ────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.name_prefix}-app-${var.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "data" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.name_prefix}-data-${var.azs[count.index]}", Tier = "data" }
}

# ── Public routing (via IGW) ─────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private routing (default route added by bastion-nat module) ──────────────
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "app" {
  count          = length(aws_subnet.app)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "data" {
  count          = length(aws_subnet.data)
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.private.id
}
