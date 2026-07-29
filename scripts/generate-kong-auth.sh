#!/usr/bin/env bash
# generate-kong-auth.sh
# Renders the authentication section of kong/<service>.yml from
# services/<service>.config.yaml. This keeps the Kong consumer + API key in ONE
# place (the service config `auth` block) rather than hand-maintained in the
# declarative config.
#
# It manages ONLY:
#   - the service's key-auth plugin (using auth.api_key_header)
#   - the consumers[] list (a single static UAT consumer)
# It deliberately does NOT add a rate-limiting plugin — rate limiting is off for
# the UAT pilot. Route paths are managed separately by generate-kong-routes.sh.
#
# Usage:
#   ./scripts/generate-kong-auth.sh <service>
#
# <service> selects services/<service>.config.yaml and kong/<service>.yml.
# Run generate-kong-routes.sh first — it seeds the per-service kong file.
#
# Prerequisites: yq (https://github.com/mikefarah/yq)

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <service>" >&2
    echo "Example: $0 organisation-catalogue" >&2
    exit 1
fi
SERVICE="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/services/${SERVICE}.config.yaml"
KONG_FILE="${REPO_ROOT}/kong/${SERVICE}.yml"

if ! command -v yq &>/dev/null; then
    echo "ERROR: 'yq' is required but not found in PATH." >&2
    exit 1
fi
for f in "${CONFIG_FILE}"; do
    [[ -f "$f" ]] || { echo "ERROR: not found: $f" >&2; exit 1; }
done
if [[ ! -f "${KONG_FILE}" ]]; then
    echo "ERROR: ${KONG_FILE} not found — run generate-kong-routes.sh ${SERVICE} first to seed it." >&2
    exit 1
fi

# --- Read the single source of truth ---
CONSUMER="$(yq '.auth.kong_consumer' "${CONFIG_FILE}")"
API_KEY="$(yq '.auth.api_key' "${CONFIG_FILE}")"
HEADER="$(yq '.auth.api_key_header' "${CONFIG_FILE}")"

for v in CONSUMER API_KEY HEADER; do
    if [[ -z "${!v}" || "${!v}" == "null" ]]; then
        echo "ERROR: auth.$(echo "$v" | tr '[:upper:]' '[:lower:]') is missing from ${CONFIG_FILE}" >&2
        exit 1
    fi
done

echo "Rendering Kong auth from ${CONFIG_FILE}:"
echo "  consumer   : ${CONSUMER}"
echo "  key header : ${HEADER}"
echo "  api key    : ${API_KEY}   (UAT static, non-secret)"

export CONSUMER API_KEY HEADER

# --- Update kong.yml (key-auth plugin + single consumer; no rate limiting) ---
yq -i '
  .services[0].plugins = [
    {"name": "key-auth", "config": {"key_names": [strenv(HEADER)]}}
  ] |
  .consumers = [
    {"username": strenv(CONSUMER), "keyauth_credentials": [{"key": strenv(API_KEY)}]}
  ]
' "${KONG_FILE}"

# --- Validate ---
if yq '.' "${KONG_FILE}" > /dev/null 2>&1; then
    echo "Validation: ${KONG_FILE} is valid YAML."
else
    echo "ERROR: ${KONG_FILE} failed YAML validation after update!" >&2
    exit 1
fi

echo "Done. Routes were NOT modified (run generate-kong-routes.sh for those)."
