# ── AMI (Ubuntu 22.04 LTS) — passed in from the environment ──────────────────
# (The environment does one AMI lookup and shares it across all tiers.)

# ── K8s node (PRIVATE — no public IP; reached via the bastion) ───────────────
resource "aws_instance" "k8s_node" {
  ami                  = var.ami_id
  instance_type        = var.instance_type
  key_name             = var.key_name
  iam_instance_profile = var.iam_instance_profile

  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.k8s_node_sg.id]
  associate_public_ip_address = false

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
