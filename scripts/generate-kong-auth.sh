#!/usr/bin/env bash
# generate-kong-auth.sh
# Renders the authentication section of kong/kong.yml from service.config.yaml.
# This keeps the Kong consumer + API key in ONE place (service.config.yaml
# `auth`) rather than hand-maintained in the declarative config.
#
# It manages ONLY:
#   - the service's key-auth plugin (using auth.api_key_header)
#   - the consumers[] list (a single static UAT consumer)
# It deliberately does NOT add a rate-limiting plugin — rate limiting is off for
# the UAT pilot. Route paths are managed separately by generate-kong-routes.sh.
#
# Usage:
#   ./scripts/generate-kong-auth.sh
#
# Prerequisites: yq (https://github.com/mikefarah/yq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KONG_FILE="${REPO_ROOT}/kong/kong.yml"
CONFIG_FILE="${REPO_ROOT}/service.config.yaml"

if ! command -v yq &>/dev/null; then
    echo "ERROR: 'yq' is required but not found in PATH." >&2
    exit 1
fi
for f in "${KONG_FILE}" "${CONFIG_FILE}"; do
    [[ -f "$f" ]] || { echo "ERROR: not found: $f" >&2; exit 1; }
done

# --- Read the single source of truth ---
CONSUMER="$(yq '.auth.kong_consumer' "${CONFIG_FILE}")"
API_KEY="$(yq '.auth.api_key' "${CONFIG_FILE}")"
HEADER="$(yq '.auth.api_key_header' "${CONFIG_FILE}")"

for v in CONSUMER API_KEY HEADER; do
    if [[ -z "${!v}" || "${!v}" == "null" ]]; then
        echo "ERROR: auth.$(echo "$v" | tr '[:upper:]' '[:lower:]') is missing from service.config.yaml" >&2
        exit 1
    fi
done

echo "Rendering Kong auth from service.config.yaml:"
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
    echo "Validation: kong.yml is valid YAML."
else
    echo "ERROR: kong.yml failed YAML validation after update!" >&2
    exit 1
fi

echo "Done. Routes were NOT modified (run generate-kong-routes.sh for those)."
