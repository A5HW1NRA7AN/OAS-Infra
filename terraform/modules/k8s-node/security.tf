# Security group for the private k8s node. SG-to-SG references only — no
# 0.0.0.0/0. SSH + Kubernetes API come from the bastion; Kong's NodePort is
# reachable only from the nginx tier. Node-to-node traffic is allowed via self.
#
# NOTE: the "Kong NodePort 30080 from nginx" ingress rule is intentionally NOT
# here — it lives in the environment (as a standalone rule) to avoid a
# k8s-node <-> nginx module dependency cycle (nginx needs this node's private IP
# for its upstream).

resource "aws_security_group" "k8s_node_sg" {
  name        = "${var.cluster_name}-node-sg"
  description = "Private K8s node: SSH/API from bastion, node-to-node, egress via NAT"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  ingress {
    description     = "Kubernetes API (6443) from bastion (kubectl/helm via ProxyJump)"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  ingress {
    description = "Node-to-node (all) within the cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.cluster_name}-node-sg" }
}
