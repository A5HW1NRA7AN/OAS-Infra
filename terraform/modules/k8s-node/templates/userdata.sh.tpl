#!/bin/bash
# Bootstrapping script for OAS-Infra Single K8s Node
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl gnupg lsb-release git ca-certificates unzip jq

# 1. Install Docker & containerd
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Allow ubuntu user to execute docker
usermod -aG docker ubuntu

# 2. Install AWS CLI v2 (for ECR auth)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws

# 3. Local Path Provisioner directory
mkdir -p /opt/local-path-provisioner
