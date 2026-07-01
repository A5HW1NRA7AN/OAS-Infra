#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <environment>"
  exit 1
fi
ENV_NAME="$1"

# Resolve directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
KUBESPRAY_DIR="${KUBESPRAY_DIR:-$REPO_ROOT/../kubespray-upstream}"
KUBESPRAY_ENV="${KUBESPRAY_ENV:-$REPO_ROOT/../kubespray-venv}"

if [ ! -d "$KUBESPRAY_DIR" ]; then
  echo "Cloning Kubespray into $KUBESPRAY_DIR..."
  git clone https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
  cd "$KUBESPRAY_DIR"
  git checkout tags/v2.24.1 # Standard stable version
  cd -
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

# Run playbook via Docker to avoid Python version issues
docker run --rm \
  --mount type=bind,source="${KUBESPRAY_DIR}/inventory",dst=/kubespray/inventory \
  --mount type=bind,source="${KEY_PATH}",dst=/root/.ssh/id_rsa \
  quay.io/kubespray/kubespray:v2.24.1 \
  ansible-playbook -i inventory/$ENV_NAME/hosts.yaml --become --become-user=root -u ubuntu --private-key=/root/.ssh/id_rsa cluster.yml

echo "==> Kubespray deployment complete."
