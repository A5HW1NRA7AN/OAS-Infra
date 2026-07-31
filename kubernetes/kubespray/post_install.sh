#!/usr/bin/env bash
# Post-install config on the PRIVATE k8s node, reached through the bastion:
# namespaces, local-path storage, ECR pull secret, and a local kubeconfig that
# works over the bastion tunnel (server stays 127.0.0.1:6443 with the REAL CA —
# no insecure-skip-tls-verify; the node's private IP + 127.0.0.1 are in the API
# cert SANs via supplementary_addresses_in_ssl_keys).
set -euo pipefail

ENV_NAME="${1:-oas-uat}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"   # kubernetes/kubespray -> repo root
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"

# shellcheck disable=SC1091
[ -f "$ENV_DIR/env.sh" ] && source "$ENV_DIR/env.sh" || { echo "Error: $ENV_DIR/env.sh not found (run terraform apply first)." >&2; exit 1; }

ssh_node() {
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
      "ubuntu@$NODE_PRIVATE_IP" "$@"
}

echo "==> Post-install on private node $NODE_PRIVATE_IP (via bastion $BASTION_IP)..."
ssh_node 'bash -s' <<'EOF'
  set -e
  echo "=> Fetching admin.conf..."
  mkdir -p ~/.kube
  sudo cp /etc/kubernetes/admin.conf ~/.kube/config
  sudo chown $(id -u):$(id -g) ~/.kube/config

  echo "=> Creating namespaces (platform, app)..."
  kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -

  echo "=> Installing local-path-provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  echo "=> Creating ECR pull secret in 'app' namespace (via instance-profile IMDS)..."
  ECR_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${ECR_REGION}.amazonaws.com"
  ECR_TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}")
  kubectl create secret docker-registry ecr-pull-secret \
      --namespace app \
      --docker-server="${ECR_REGISTRY}" \
      --docker-username=AWS \
      --docker-password="${ECR_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -
  echo "=> Post-install on node complete."
EOF

echo "==> Retrieving kubeconfig (leaves server=127.0.0.1:6443 + real CA for tunnel use)..."
scp -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
    "ubuntu@$NODE_PRIVATE_IP:~/.kube/config" "$REPO_ROOT/scratch_kubeconfig"

echo "==> kubeconfig saved to $REPO_ROOT/scratch_kubeconfig"
echo "    Use it WITH an API tunnel open (scripts/lib/kube-tunnel.sh open_kube_tunnel),"
echo "    since the server is 127.0.0.1:6443 reached through the bastion."
