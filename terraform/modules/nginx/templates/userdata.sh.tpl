#!/bin/bash
# nginx reverse-proxy bootstrap (Ubuntu 22.04). Forwards :80 -> Kong :30080.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# Retry apt in case the NAT route/bastion isn't fully up yet at first boot.
for i in $(seq 1 10); do apt-get update -y && break || sleep 15; done
apt-get install -y nginx

cat >/etc/nginx/sites-available/oas.conf <<'NGINX'
server {
    listen 80 default_server;
    server_name _;

    # Preserve original Host/forwarding headers so Kong route matching + logging work.
    location / {
        proxy_pass http://${kong_upstream};
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/oas.conf /etc/nginx/sites-enabled/oas.conf
nginx -t
systemctl enable nginx
systemctl restart nginx
echo "nginx proxying :80 -> ${kong_upstream}"
