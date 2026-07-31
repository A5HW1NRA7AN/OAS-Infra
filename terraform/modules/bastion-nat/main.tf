# bastion-nat module — public jump host that ALSO acts as the NAT instance for
# the private subnets (no managed NAT Gateway, to save cost for UAT).
#
# It: (1) accepts admin SSH on 22, (2) forwards + masquerades traffic from the
# VPC CIDR so private app/data instances get internet egress (ECR/apt/Kubespray
# pulls), and (3) installs the 0.0.0.0/0 -> this-ENI default route on the
# private route table.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion-sg"
  description = "Bastion/NAT: admin SSH + NAT for private subnets"
  vpc_id      = var.vpc_id

  ingress {
    description = "Admin SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_ssh_cidrs
  }

  ingress {
    description = "NAT: forward all traffic originating inside the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true
  # Required for a NAT instance: allow forwarding packets not addressed to itself.
  source_dest_check = false

  user_data = templatefile("${path.module}/templates/userdata.sh.tpl", {
    vpc_cidr = var.vpc_cidr
  })

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.name_prefix}-bastion" }

  # Pin the AMI: `data.aws_ami { most_recent = true }` drifts to newer Ubuntu
  # images over time; without this, a routine `terraform apply` would DESTROY and
  # replace this instance (new IP, NAT re-setup — a full outage).
  lifecycle {
    ignore_changes = [ami]
  }
}

# NOTE: No Elastic IP — the account is at its EIP quota. The auto-assigned public
# IP is stable while the instance runs (only changes on stop/start), which is
# fine for this UAT.

# Private subnets reach the internet via the bastion NAT instance.
resource "aws_route" "private_default" {
  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.bastion.primary_network_interface_id
}
