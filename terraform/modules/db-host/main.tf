# db-host module — the data tier. ONE private EC2 running all databases as
# Docker containers (Postgres/Elasticsearch/Redis) plus admin GUIs, via
# docker-compose. Databases deliberately do NOT run in Kubernetes (StatefulSets
# proved unreliable for this use case).
#
# user_data only installs Docker + compose. The compose stack, init SQL, and
# .env (secrets) are delivered separately by scripts/setup-cluster.sh over the
# bastion, so no secret is ever baked into user_data. The instance gets a FIXED
# private IP so the app's SPRING_DATASOURCE_URL / ELASTICSEARCH_HOST /
# SPRING_REDIS_HOST are stable without Route53.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

resource "aws_security_group" "db_host" {
  name        = "${var.name_prefix}-db-host-sg"
  description = "DB host: DB ports from k8s nodes; SSH+GUIs from bastion only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from k8s nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.k8s_node_sg_id]
  }
  ingress {
    description     = "Elasticsearch from k8s nodes"
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = [var.k8s_node_sg_id]
  }
  ingress {
    description     = "Redis from k8s nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.k8s_node_sg_id]
  }
  ingress {
    description     = "SSH from bastion only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }
  ingress {
    description     = "pgAdmin from bastion only (reached via SSH tunnel)"
    from_port       = 5050
    to_port         = 5050
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }
  ingress {
    description     = "RedisInsight (5540) + Kibana (5601) from bastion only (SSH tunnel)"
    from_port       = 5540
    to_port         = 5601
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-db-host-sg" }
}

resource "aws_instance" "db_host" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.data_subnet_id
  private_ip                  = var.private_ip
  vpc_security_group_ids      = [aws_security_group.db_host.id]
  associate_public_ip_address = false

  user_data = file("${path.module}/templates/userdata.sh.tpl")

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = { Name = "${var.name_prefix}-db-host" }
}
