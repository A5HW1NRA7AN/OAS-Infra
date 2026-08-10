#!/usr/bin/env bash
# Open an SSH tunnel through the bastion to the private k8s API (127.0.0.1:6443,
# real CA -> full TLS) so kubectl/helm/deck can reach the cluster. Source this +
# env.sh, then use: open_kube_tunnel [localport] / close_kube_tunnel.

KUBE_TUNNEL_CTL="${KUBE_TUNNEL_CTL:-${TMPDIR:-/tmp}/oas-kube-tunnel.sock}"

open_kube_tunnel() {
  : "${BASTION_IP:?source env.sh first}"
  : "${NODE_PRIVATE_IP:?source env.sh first}"
  : "${KEY_PATH:?source env.sh first}"
  local lport="${1:-6443}"
  close_kube_tunnel
  ssh -M -S "$KUBE_TUNNEL_CTL" -fN \
    -L "${lport}:${NODE_PRIVATE_IP}:6443" \
    -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ubuntu@${BASTION_IP}"
  echo "kube API tunnel up: localhost:${lport} -> ${NODE_PRIVATE_IP}:6443 (via ${BASTION_IP})"
}

close_kube_tunnel() {
  [ -S "$KUBE_TUNNEL_CTL" ] || return 0
  ssh -S "$KUBE_TUNNEL_CTL" -O exit "ubuntu@${BASTION_IP:-unknown}" 2>/dev/null || true
  rm -f "$KUBE_TUNNEL_CTL" 2>/dev/null || true
}
