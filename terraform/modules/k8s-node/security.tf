# Security group for the private k8s node. SG-to-SG references only — no
# 0.0.0.0/0. SSH + Kubernetes API come from the bastion; Kong's NodePort is
# reachable only from the nginx tier. Node-to-node traffic is allowed via self.
#
# IMPORTANT: rules are defined as STANDALONE aws_security_group_rule resources,
# NOT inline `ingress` blocks. This is deliberate: the "Kong NodePort 30080 from
# nginx" rule lives in the environment (a standalone rule, to avoid a k8s-node <->
# nginx module dependency cycle). The AWS provider forbids mixing inline rules
# with standalone rules on the same SG — inline blocks silently DELETE standalone
# rules on every apply (this caused nginx->Kong 504s). Keeping ALL rules
# standalone makes them coexist safely.

resource "aws_security_group" "k8s_node_sg" {
  name        = "${var.cluster_name}-node-sg"
  description = "Private K8s node: SSH/API from bastion, node-to-node, egress via NAT"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.cluster_name}-node-sg" }
}

resource "aws_security_group_rule" "node_ssh_from_bastion" {
  type                     = "ingress"
  description              = "SSH from bastion"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.k8s_node_sg.id
  source_security_group_id = var.bastion_sg_id
}

resource "aws_security_group_rule" "node_api_from_bastion" {
  type                     = "ingress"
  description              = "Kubernetes API (6443) from bastion (kubectl/helm via ProxyJump)"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.k8s_node_sg.id
  source_security_group_id = var.bastion_sg_id
}

resource "aws_security_group_rule" "node_self" {
  type              = "ingress"
  description       = "Node-to-node (all) within the cluster"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.k8s_node_sg.id
  self              = true
}

resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  description       = "Egress (all) via the bastion NAT"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.k8s_node_sg.id
  cidr_blocks       = ["0.0.0.0/0"]
}
