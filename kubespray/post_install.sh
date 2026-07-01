#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <environment>"
  exit 1
fi
ENV_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"

# Find env.sh
if [ -f "$ENV_DIR/env.sh" ]; then
  source "$ENV_DIR/env.sh"
else
  echo "Error: env.sh not found in $ENV_DIR." >&2
  exit 1
fi

echo "==> Running post-install configurations on the K8s node..."

ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$NODE_IP << 'EOF'
  set -e
  
  echo "=> Fetching admin.conf..."
  mkdir -p ~/.kube
  sudo cp /etc/kubernetes/admin.conf ~/.kube/config
  sudo chown $(id -u):$(id -g) ~/.kube/config

  echo "=> Creating namespaces..."
  kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -

  echo "=> Installing local-path-provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  echo "=> Retrieving ECR pull token..."
  ECR_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${ECR_REGION}.amazonaws.com"
  
  ECR_TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}")
  
  echo "=> Creating ECR pull secret in 'app' namespace..."
  kubectl create secret docker-registry ecr-pull-secret \
      --namespace app \
      --docker-server="${ECR_REGISTRY}" \
      --docker-username=AWS \
      --docker-password="${ECR_TOKEN}" \
      --dry-run=client -o yaml | kubectl apply -f -

  echo "=> Post-install configuration complete."
EOF

echo "==> Retrieving kubeconfig to local machine..."
scp -i "$KEY_PATH" -o StrictHostKeyChecking=no ubuntu@$NODE_IP:~/.kube/config "$REPO_ROOT/scratch_kubeconfig"

# Replace 127.0.0.1 with the public IP
sed -i.bak "s/127.0.0.1/$NODE_IP/g" "$REPO_ROOT/scratch_kubeconfig"

echo "==> Local kubeconfig saved to $REPO_ROOT/scratch_kubeconfig"
echo "To use it: export KUBECONFIG=$REPO_ROOT/scratch_kubeconfig"

echo "==> Next steps:"
echo "1. Run data services (Postgres, Redis, Elasticsearch) via Helm."
echo "2. Provide postgres-creds secret."
