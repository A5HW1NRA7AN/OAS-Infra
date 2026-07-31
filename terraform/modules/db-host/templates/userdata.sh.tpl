#!/bin/bash
# DB host bootstrap (Ubuntu 22.04): install Docker + compose plugin ONLY.
# The compose stack, init SQL, and .env (secrets) are delivered afterwards by
# scripts/setup-cluster.sh over the bastion — so no secret is ever in user_data.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Retry: at first boot the bastion NAT route may not be ready yet.
for i in $(seq 1 15); do
  if apt-get update -y; then break; fi
  echo "apt-get update failed (NAT not ready?), retry $i/15"; sleep 20
done

apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  >/etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu
systemctl enable --now docker

# Elasticsearch needs a higher mmap count.
echo 'vm.max_map_count=262144' >/etc/sysctl.d/99-es.conf
sysctl -p /etc/sysctl.d/99-es.conf

mkdir -p /opt/oas-db
chown ubuntu:ubuntu /opt/oas-db
echo "db-host docker ready — awaiting compose stack from setup-cluster.sh"
