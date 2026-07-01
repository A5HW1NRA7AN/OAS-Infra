# ── AMI (Ubuntu 22.04 LTS) ────────────────────────────────────────────────────

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

# ── Instances ─────────────────────────────────────────────────────────────────

resource "aws_instance" "k8s_node" {
  ami                  = data.aws_ami.ubuntu_22_04.id
  instance_type        = var.instance_type
  key_name             = aws_key_pair.oas_key_pair.key_name
  iam_instance_profile = var.iam_instance_profile

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.k8s_node_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = file("${path.module}/templates/userdata.sh.tpl")

  tags = {
    Name = "${var.cluster_name}-K8s-Node"
  }

  lifecycle {
    ignore_changes = [key_name]
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
# Temporarily disabled due to AWS quota limits for the UAT pilot
# resource "aws_eip" "node_eip" {
#   domain   = "vpc"
#   instance = aws_instance.k8s_node.id
# 
#   tags = {
#     Name = "${var.cluster_name}-eip"
#   }
# }
