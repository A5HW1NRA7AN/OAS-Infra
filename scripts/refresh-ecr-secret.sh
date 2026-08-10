#!/usr/bin/env bash
# Refresh the ECR pull secret in the 'app' namespace. ECR tokens expire ~12h on
# self-managed clusters (no IRSA); run on the k8s node via cron (see post_install.sh).
set -euo pipefail

SECRET_NAME="ecr-pull-secret"
NAMESPACE="app"

# Region from IMDSv2 (running on the node), falling back to AWS_REGION.
TOKEN="$(curl -s --max-time 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
ECR_REGION="$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region || true)"
if [ -z "${ECR_REGION}" ]; then
  ECR_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi

if [ -z "${ECR_REGION}" ]; then
  echo "ERROR: Could not determine AWS region (instance metadata and AWS_REGION both empty)." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
    echo "ERROR: Failed to resolve AWS account ID. Verify the instance profile / credentials." >&2
    exit 1
}
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${ECR_REGION}.amazonaws.com"

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Refreshing ECR pull secret for ${ECR_REGISTRY}..."

ECR_TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}") || {
    echo "ERROR: Failed to get ECR login token. Verify the instance profile has AmazonEC2ContainerRegistryReadOnly." >&2
    exit 1
}

# create --dry-run | apply is idempotent (avoids "already exists").
kubectl create secret docker-registry "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --docker-server="${ECR_REGISTRY}" \
    --docker-username=AWS \
    --docker-password="${ECR_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ECR pull secret '${SECRET_NAME}' refreshed in namespace '${NAMESPACE}'."
