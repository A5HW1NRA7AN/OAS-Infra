#!/usr/bin/env bash
# Rotate a consumer's API key: generate a fresh key, replace it via the private
# Kong Admin API (over the bastion), update kong/.env so deck-sync stays
# consistent, and print the new key.
#   Usage: kong/scripts/rotate-key.sh <user|admin|superadmin>
set -euo pipefail

CONSUMER="${1:-}"
case "$CONSUMER" in
  user|admin|superadmin) ;;
  *) echo "Usage: $0 <user|admin|superadmin>" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/terraform/environments/oas-uat"
KONG_ADMIN_SVC="${KONG_ADMIN_SVC:-kong-kong-admin}"
KONG_ADMIN_NS="${KONG_ADMIN_NS:-platform}"
# Kong Admin API is TLS on 8444 (ClusterIP, never public).
KONG_ADMIN_PORT="${KONG_ADMIN_PORT:-8444}"
ENV_VAR="OAS_$(echo "$CONSUMER" | tr '[:lower:]' '[:upper:]')_API_KEY"

for c in ssh kubectl curl jq openssl; do command -v "$c" >/dev/null || { echo "ERROR: '$c' not found" >&2; exit 1; }; done

# shellcheck disable=SC1091
source "${ENV_DIR}/env.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/kube-tunnel.sh"
export KUBECONFIG="${REPO_ROOT}/scratch_kubeconfig"

cleanup() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; close_kube_tunnel; }
trap cleanup EXIT

open_kube_tunnel 6443
kubectl -n "$KONG_ADMIN_NS" port-forward "svc/${KONG_ADMIN_SVC}" "${KONG_ADMIN_PORT}:${KONG_ADMIN_PORT}" >/dev/null 2>&1 &
PF_PID=$!
sleep 4
ADMIN="https://localhost:${KONG_ADMIN_PORT}"   # TLS admin; -k for the self-signed cert

NEWKEY="$(openssl rand -hex 24)"

# Delete existing key-auth credentials for the consumer, then add the new one.
echo "Rotating key for consumer '${CONSUMER}'..."
for id in $(curl -sk "${ADMIN}/consumers/${CONSUMER}/key-auth" | jq -r '.data[].id'); do
  curl -sk -X DELETE "${ADMIN}/consumers/${CONSUMER}/key-auth/${id}" >/dev/null
done
curl -sk -X POST "${ADMIN}/consumers/${CONSUMER}/key-auth" --data "key=${NEWKEY}" >/dev/null

# Keep kong/.env in sync so deck-sync.sh won't revert the rotation.
ENVFILE="${REPO_ROOT}/kong/.env"
if [ -f "$ENVFILE" ] && grep -q "^${ENV_VAR}=" "$ENVFILE"; then
  sed -i.bak "s|^${ENV_VAR}=.*|${ENV_VAR}=${NEWKEY}|" "$ENVFILE" && rm -f "${ENVFILE}.bak"
  echo "Updated ${ENV_VAR} in kong/.env"
else
  echo "NOTE: add ${ENV_VAR}=${NEWKEY} to kong/.env"
fi

echo ""
echo "New ${CONSUMER} API key (hand to the developer, use with header 'apikey'):"
echo "    ${NEWKEY}"
echo "Base URL: http://${NGINX_IP}"
