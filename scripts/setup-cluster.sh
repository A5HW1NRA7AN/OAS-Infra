#!/bin/bash
# setup-cluster.sh
# Orchestrates the full cluster deployment: Terraform provisioning, Kubespray,
# data services (PostgreSQL/Redis/Elasticsearch), and the Kong gateway.
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <environment>"
  echo "Example: $0 agri-catalogue"
  exit 1
fi

ENV_NAME="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/$ENV_NAME"
CONFIG_FILE="$REPO_ROOT/service.config.yaml"

if [ ! -d "$ENV_DIR" ]; then
  echo "Error: Environment directory not found at $ENV_DIR"
  exit 1
fi

# --- Pre-flight: required tooling ---
for cmd in terraform helm kubectl yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

# --- Read the single source of truth (never hardcode these here) ---
DB_NAME="$(yq '.database.name' "$CONFIG_FILE")"
DB_USER="$(yq '.database.username' "$CONFIG_FILE")"

echo "=== OAS-Infra Cluster Setup ($ENV_NAME) ==="
echo "    Database: $DB_NAME (user: $DB_USER)"
echo ""
echo "    Instance sizing is a Terraform variable. To use a larger node than the"
echo "    t3.xlarge default (e.g. for heavier Elasticsearch/data workloads), set:"
echo "        export TF_VAR_instance_type=t3.2xlarge"
echo "    before running this script, or override in a *.tfvars file."

# ─────────────────────────────────────────────────────────────────────────────
# Single-node capacity budget (t3.xlarge = 4 vCPU / 16 GB floor)
# Tune these if you move to a larger instance. The goal is that no single
# component starves another on the shared node.
#
#   Component        req mem / cpu     limit mem / cpu   notes
#   ---------        ------------      ---------------   -----
#   kube + system    ~2-3 Gi           (reserved)        etcd/apiserver/kubelet
#   Elasticsearch    2 Gi / 500m       3 Gi / 1          heap pinned to 1 Gi
#   PostgreSQL       512 Mi / 250m     1 Gi / 500m
#   Redis            256 Mi / 100m     512 Mi / 250m
#   Kong             256 Mi / 100m     512 Mi / 500m
#   catalogue-app    512 Mi / 250m     1 Gi / 500m       (from service.config.yaml)
# ─────────────────────────────────────────────────────────────────────────────

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
if [ -z "${PG_PASSWORD:-}" ]; then
  read -s -p "Enter a password for PostgreSQL '$DB_USER': " PG_PASSWORD
  echo ""
fi

kubectl create secret generic postgres-creds -n data \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install postgres bitnami/postgresql -n data \
  --set auth.existingSecret=postgres-creds \
  --set auth.database="$DB_NAME" \
  --set primary.persistence.size=20Gi \
  --set primary.resources.requests.cpu=250m \
  --set primary.resources.requests.memory=512Mi \
  --set primary.resources.limits.cpu=500m \
  --set primary.resources.limits.memory=1Gi

helm upgrade --install redis bitnami/redis -n data \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.persistence.size=5Gi \
  --set master.resources.requests.cpu=100m \
  --set master.resources.requests.memory=256Mi \
  --set master.resources.limits.cpu=250m \
  --set master.resources.limits.memory=512Mi

helm upgrade --install elasticsearch bitnami/elasticsearch -n data \
  --set master.replicaCount=1 \
  --set data.replicaCount=1 \
  --set coordinating.replicaCount=0 \
  --set ingest.replicaCount=0 \
  --set security.enabled=false \
  --set volumePermissions.enabled=true \
  --set master.persistence.size=20Gi \
  --set master.heapSize=1024m \
  --set master.resources.requests.cpu=500m \
  --set master.resources.requests.memory=2Gi \
  --set master.resources.limits.cpu=1 \
  --set master.resources.limits.memory=3Gi

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
echo "Next, render and apply the Kong declarative config:"
echo "  1. Generate routes from the live app:   ./scripts/generate-kong-routes.sh"
echo "  2. Render the UAT consumer + API key:   ./scripts/generate-kong-auth.sh"
echo "  3. Apply as a ConfigMap:"
echo "     kubectl create configmap kong-config -n platform \\"
echo "       --from-file=kong.yml=kong/kong.yml -o yaml --dry-run=client | kubectl apply -f -"
echo "     kubectl rollout restart deployment kong -n platform"
echo "  (Rate limiting is intentionally OFF for UAT; auth is a single static key.)"

echo ""
echo "=== Setup Complete ==="
echo "You can now run Jenkins locally or via jenkins/terraform to deploy the application."
