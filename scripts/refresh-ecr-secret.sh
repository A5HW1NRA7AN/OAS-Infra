#!/usr/bin/env bash
# refresh-ecr-secret.sh
# Refreshes the ECR pull secret in the app namespace.
# ECR tokens expire every 12 hours on self-managed clusters (no IRSA).
# Run this manually or via a host-level cron job every 6 hours.
#
# Usage:
#   ./scripts/refresh-ecr-secret.sh
#
# Prerequisites:
#   - aws CLI (uses instance profile for auth — no hardcoded credentials)
#   - kubectl (with access to the cluster)
#
# Cron example (add to the EC2 host's crontab):
#   0 */6 * * * /path/to/scripts/refresh-ecr-secret.sh >> /var/log/ecr-refresh.log 2>&1

set -euo pipefail

ECR_REGION="ap-south-1"
ECR_REGISTRY="379220350808.dkr.ecr.${ECR_REGION}.amazonaws.com"
SECRET_NAME="ecr-pull-secret"
NAMESPACE="app"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Refreshing ECR pull secret..."

# Get a fresh ECR login token using the instance profile
ECR_TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}") || {
    echo "ERROR: Failed to get ECR login token. Verify the instance profile has AmazonEC2ContainerRegistryReadOnly." >&2
    exit 1
}

# Delete the existing secret (if any) and recreate it.
# kubectl create --dry-run + apply pattern avoids "already exists" errors.
kubectl create secret docker-registry "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --docker-server="${ECR_REGISTRY}" \
    --docker-username=AWS \
    --docker-password="${ECR_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ECR pull secret '${SECRET_NAME}' refreshed in namespace '${NAMESPACE}'."
