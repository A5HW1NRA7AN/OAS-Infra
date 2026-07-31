# iam module — instance profile for the k8s node so it can pull images from ECR
# via IMDS (aws ecr get-login-password) with no static credentials. Replaces the
# previous name-only reference to a pre-existing "EC2-ECR-Read-Role".

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecr_read" {
  name               = "${var.name_prefix}-ecr-read-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.name_prefix}-ecr-read-role" }
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ecr_read.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ecr_read" {
  name = "${var.name_prefix}-ecr-read-profile"
  role = aws_iam_role.ecr_read.name
}
