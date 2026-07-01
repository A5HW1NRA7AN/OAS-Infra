#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <environment>"
  exit 1
fi
ENV_NAME="$1"

# Resolve directories
SCRIPT_DIR="$(cd "$(dirname "$${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"

# Find env.sh
if [ -f "$ENV_DIR/env.sh" ]; then
  source "$ENV_DIR/env.sh"
else
  echo "Error: env.sh not found. Please run 'terraform apply' first in the $ENV_DIR directory." >&2
  exit 1
fi

# Ensure file permissions on private key are correct
chmod 600 "$KEY_PATH"

# Path to Kubespray repository
KUBESPRAY_DIR="${KUBESPRAY_DIR:-/home/rajan/Projects/kubespray}"
KUBESPRAY_ENV="${KUBESPRAY_ENV:-/home/rajan/Projects/kubespray-venv}"

if [ ! -d "$KUBESPRAY_DIR" ]; then
  echo "Error: Kubespray directory not found at $KUBESPRAY_DIR" >&2
  echo "Please clone it: git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAY_DIR" >&2
  exit 1
fi

echo "==> Deploying Kubespray..."

# Locate and copy hosts_k8s.yaml
if [ -f "$ENV_DIR/hosts_k8s.yaml" ]; then
  mkdir -p "$KUBESPRAY_DIR/inventory/$ENV_NAME"
  cp -f "$ENV_DIR/hosts_k8s.yaml" "$KUBESPRAY_DIR/inventory/$ENV_NAME/hosts.yaml"
else
  echo "Error: hosts_k8s.yaml not found. Please run 'terraform apply' first." >&2
  exit 1
fi

# Ensure container_manager is set to containerd
mkdir -p "$KUBESPRAY_DIR/inventory/$ENV_NAME/group_vars/k8s_cluster"
cat <<EOF > "$KUBESPRAY_DIR/inventory/$ENV_NAME/group_vars/k8s_cluster/k8s-cluster.yml"
container_manager: containerd
kube_proxy_mode: iptables
EOF

# Run playbook
cd "$KUBESPRAY_DIR"
source "$KUBESPRAY_ENV/bin/activate" || true
ansible-playbook -i inventory/$ENV_NAME/hosts.yaml --become --become-user=root -u ubuntu --private-key="$KEY_PATH" cluster.yml

echo "==> Kubespray deployment complete."
