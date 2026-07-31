#!/usr/bin/env bash
# Shared helper: open an SSH tunnel THROUGH the bastion to the private k8s API
# so kubectl/helm/deck (run from a laptop or Jenkins outside the VPC) can reach
# the cluster. The kubeconfig from Kubespray already points at 127.0.0.1:6443
# with a real CA, so once this tunnel is up, kubectl works with full TLS
# verification (no insecure-skip-tls-verify).
#
# Usage:
#   source "$(dirname "$0")/lib/kube-tunnel.sh"   # (adjust path)
#   source terraform/environments/oas-uat/env.sh  # BASTION_IP/NODE_PRIVATE_IP/KEY_PATH
#   open_kube_tunnel            # localhost:6443 -> node:6443
#   trap close_kube_tunnel EXIT
#   export KUBECONFIG=...; kubectl get nodes

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
