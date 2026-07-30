#!/usr/bin/env bash
# Sync kong/kong.decK.yaml into the DB-backed Kong via decK, over the bastion.
#
# API keys for the 3 consumers are NOT in the repo — they come from kong/.env
# (gitignored) or the environment (Jenkins), and decK resolves the
# ${{ env "OAS_*_API_KEY" }} placeholders at sync time.
#
# Prereqs: ssh, kubectl, deck (https://github.com/Kong/deck). Run after the
# cluster + Kong (DB mode) are up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/terraform/environments/oas-uat"
KONG_ADMIN_SVC="${KONG_ADMIN_SVC:-kong-kong-admin}"
KONG_ADMIN_NS="${KONG_ADMIN_NS:-platform}"
KONG_ADMIN_PORT="${KONG_ADMIN_PORT:-8001}"

for c in ssh kubectl deck; do command -v "$c" >/dev/null || { echo "ERROR: '$c' not found" >&2; exit 1; }; done

# shellcheck disable=SC1091
source "${ENV_DIR}/env.sh"
[ -f "${REPO_ROOT}/kong/.env" ] && { set -a; . "${REPO_ROOT}/kong/.env"; set +a; }
: "${OAS_USER_API_KEY:?set in kong/.env}"; : "${OAS_ADMIN_API_KEY:?set in kong/.env}"; : "${OAS_SUPERADMIN_API_KEY:?set in kong/.env}"
export OAS_USER_API_KEY OAS_ADMIN_API_KEY OAS_SUPERADMIN_API_KEY

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/kube-tunnel.sh"
export KUBECONFIG="${REPO_ROOT}/scratch_kubeconfig"

cleanup() { [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true; close_kube_tunnel; }
trap cleanup EXIT

open_kube_tunnel 6443
kubectl -n "$KONG_ADMIN_NS" port-forward "svc/${KONG_ADMIN_SVC}" "${KONG_ADMIN_PORT}:${KONG_ADMIN_PORT}" >/dev/null 2>&1 &
PF_PID=$!
sleep 4

echo "== deck ping =="
deck gateway ping --kong-addr "http://localhost:${KONG_ADMIN_PORT}"
echo "== deck diff =="
deck gateway diff  --kong-addr "http://localhost:${KONG_ADMIN_PORT}" "${REPO_ROOT}/kong/kong.decK.yaml" || true
echo "== deck sync =="
deck gateway sync  --kong-addr "http://localhost:${KONG_ADMIN_PORT}" "${REPO_ROOT}/kong/kong.decK.yaml"
echo "Kong config synced."
