#!/bin/bash
# Bastion + NAT instance bootstrap (Ubuntu 22.04).
set -euo pipefail

# --- NAT: enable IP forwarding + masquerade traffic from the VPC ---
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-nat.conf
sysctl -p /etc/sysctl.d/99-nat.conf

# Primary (default-route) interface, e.g. ens5 on Nitro instances.
IFACE="$(ip -o -4 route show to default | awk '{print $5; exit}')"
iptables -t nat -A POSTROUTING -s ${vpc_cidr} -o "$IFACE" -j MASQUERADE
iptables -A FORWARD -s ${vpc_cidr} -j ACCEPT
iptables -A FORWARD -d ${vpc_cidr} -j ACCEPT

# Persist iptables across reboots.
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install -y iptables-persistent netfilter-persistent
netfilter-persistent save

echo "bastion-nat ready on $IFACE"
