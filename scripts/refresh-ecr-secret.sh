#!/usr/bin/env bash
# refresh-ecr-secret.sh
# Refreshes the ECR pull secret in the app namespace.
# ECR tokens expire every 12 hours on self-managed clusters (no IRSA).
# Run this manually or via a host-level cron job every 6 hours.
#
# Usage:
#   ./scripts/refresh-ecr-secret.sh
#
# Nothing is hardcoded: the AWS account ID is derived via
# `aws sts get-caller-identity` and the region from the EC2 instance metadata
# (falling back to service.config.yaml's ecr_region when run off-instance).
#
# Prerequisites:
#   - aws CLI (uses instance profile for auth — no hardcoded credentials)
#   - kubectl (with access to the cluster)
#
# Cron example (add to the EC2 host's crontab):
#   0 */6 * * * /path/to/scripts/refresh-ecr-secret.sh >> /var/log/ecr-refresh.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/service.config.yaml"

SECRET_NAME="ecr-pull-secret"
NAMESPACE="app"

# Resolve region: instance metadata first, then service.config.yaml, then AWS_REGION.
ECR_REGION="$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/placement/region || true)"
if [ -z "${ECR_REGION}" ]; then
  if command -v yq &>/dev/null && [ -f "${CONFIG_FILE}" ]; then
    ECR_REGION="$(yq '.image.ecr_region' "${CONFIG_FILE}")"
  else
    ECR_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  fi
fi

if [ -z "${ECR_REGION}" ]; then
  echo "ERROR: Could not determine AWS region (instance metadata, service.config.yaml, and AWS_REGION all empty)." >&2
  exit 1
fi

# Derive the account ID — never hardcode it.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
    echo "ERROR: Failed to resolve AWS account ID. Verify the instance profile / credentials." >&2
    exit 1
}
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${ECR_REGION}.amazonaws.com"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Refreshing ECR pull secret for ${ECR_REGISTRY}..."

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
