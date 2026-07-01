# ── SSH Key (auto-generated) ──────────────────────────────────────────────────

resource "tls_private_key" "oas_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "oas_key_pair" {
  key_name   = var.key_name
  public_key = tls_private_key.oas_key.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.oas_key.private_key_pem
  filename        = "${path.root}/oas-key.pem"
  file_permission = "0400"
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "k8s_node_sg" {
  name        = "${var.cluster_name}-node-sg"
  description = "Security group for OAS Pilot Single K8s Node"
  vpc_id      = var.vpc_id

  # SSH Ingress
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
    description = "SSH Access"
  }

  # Kong Proxy Ingress (NodePort)
  ingress {
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = var.allowed_kong_cidrs
    description = "Kong Proxy Access"
  }

  # Egress (All Traffic)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-node-sg"
  }
}
