# nginx module — the public HTTP entrypoint. Terminates :80 from the internet
# and reverse-proxies to Kong's NodePort (30080) on the private k8s node.
# HTTP only for UAT (no domain/TLS yet). SSH is via the bastion only.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

resource "aws_security_group" "nginx" {
  name        = "${var.name_prefix}-nginx-sg"
  description = "Public nginx reverse proxy"
  vpc_id      = var.vpc_id

  ingress {
    description = "Public HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "Admin SSH via bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-nginx-sg" }
}

resource "aws_instance" "nginx" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.nginx.id]
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/userdata.sh.tpl", {
    kong_upstream = "${var.kong_upstream_host}:${var.kong_upstream_port}"
  })

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.name_prefix}-nginx" }
}

resource "aws_eip" "nginx" {
  instance = aws_instance.nginx.id
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-nginx-eip" }
}
