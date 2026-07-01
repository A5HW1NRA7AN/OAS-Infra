#!/bin/bash
# setup-cluster.sh
# Orchestrates the full cluster deployment according to docs/deployment-plan.md
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <environment>"
  echo "Example: $0 agri-catalogue"
  exit 1
fi

ENV_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"

if [ ! -d "$ENV_DIR" ]; then
  echo "Error: Environment directory not found at $ENV_DIR"
  exit 1
fi

echo "=== OAS-Infra Cluster Setup ($ENV_NAME) ==="

# 1. Provision EC2 node via Terraform
echo ""
echo "[Step 1] Provisioning K8s Node..."
cd "$ENV_DIR"
terraform init
terraform apply -auto-approve

# 2. Deploy Kubespray
echo ""
echo "[Step 2] Deploying Kubernetes via Kubespray..."
cd "$REPO_ROOT"
bash ./kubespray/deploy_kubespray.sh "$ENV_NAME"

# 3. Post-install Config (Namespaces, StorageClass, ECR Secret)
echo ""
echo "[Step 3] Post-install Configuration..."
bash ./kubespray/post_install.sh "$ENV_NAME"

# Export kubeconfig to run helm/kubectl locally
export KUBECONFIG="$REPO_ROOT/scratch_kubeconfig"

# 4. Deploy Data Services (Bitnami Helm Charts)
echo ""
echo "[Step 4] Deploying Data Services (Postgres, Redis, Elasticsearch)..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Prompt for Postgres password securely if not provided via env
if [ -z "$PG_PASSWORD" ]; then
  read -s -p "Enter a password for PostgreSQL 'verg_user': " PG_PASSWORD
  echo ""
fi

kubectl create secret generic postgres-creds -n data \
  --from-literal=username=verg_user \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install postgres bitnami/postgresql -n data \
  --set auth.existingSecret=postgres-creds \
  --set auth.database=verg_db \
  --set primary.persistence.size=20Gi \
  --set primary.resources.requests.memory=512Mi \
  --set primary.resources.limits.memory=1Gi

helm upgrade --install redis bitnami/redis -n data \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.persistence.size=5Gi

helm upgrade --install elasticsearch bitnami/elasticsearch -n data \
  --set master.replicaCount=1 \
  --set data.replicaCount=1 \
  --set coordinating.replicaCount=0 \
  --set ingest.replicaCount=0 \
  --set security.enabled=false \
  --set volumePermissions.enabled=true \
  --set master.persistence.size=20Gi

# 5. Kong Gateway
echo ""
echo "[Step 5] Deploying Kong API Gateway..."
helm repo add kong https://charts.konghq.com
helm repo update

helm upgrade --install kong kong/kong -n platform \
  --set env.database=off \
  --set proxy.type=NodePort \
  --set proxy.http.nodePort=30080 \
  --set admin.enabled=true \
  --set admin.type=ClusterIP

echo ""
echo "Please update kong/kong.yml with real API keys and deploy it manually:"
echo "kubectl create configmap kong-declarative-config -n platform --from-file=kong.yml=kong/kong.yml"

echo ""
echo "=== Setup Complete ==="
echo "You can now run Jenkins locally or via jenkins/terraform to deploy the application."
