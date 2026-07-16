#!/usr/bin/env bash
# generate-kong-routes.sh
# Regenerates the route paths in kong/kong.yml by discovering top-level
# path prefixes from the application's live /v3/api-docs endpoint.
#
# Usage:
#   ./scripts/generate-kong-routes.sh [APP_URL]
#
# APP_URL defaults to the in-cluster URL from service.config.yaml:
#   http://catalogue-service.app.svc.cluster.local:8080
#
# When running from a dev machine, use a port-forwarded URL:
#   ./scripts/generate-kong-routes.sh http://localhost:8080
#
# Prerequisites: curl, jq, yq (https://github.com/mikefarah/yq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KONG_FILE="${REPO_ROOT}/kong/kong.yml"
DEFAULT_APP_URL="http://catalogue-service.app.svc.cluster.local:8080"

APP_URL="${1:-${DEFAULT_APP_URL}}"
DOCS_URL="${APP_URL}/v3/api-docs"

# --- Pre-flight checks ---
for cmd in curl jq yq; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: '${cmd}' is required but not found in PATH." >&2
        exit 1
    fi
done

if [[ ! -f "${KONG_FILE}" ]]; then
    echo "ERROR: Kong config not found at ${KONG_FILE}" >&2
    exit 1
fi

# --- Fetch OpenAPI spec ---
echo "Fetching OpenAPI spec from ${DOCS_URL} ..."
SPEC=$(curl -sf "${DOCS_URL}") || {
    echo "ERROR: Failed to fetch /v3/api-docs from ${DOCS_URL}" >&2
    echo "The application must expose a valid OpenAPI endpoint at ${DOCS_URL}." >&2
    exit 1
}

# --- Extract unique top-level path prefixes ---
echo "Extracting path prefixes..."
PREFIXES=$(echo "${SPEC}" | jq -r '.paths | keys[] | split("/") | .[1] // empty' | sort -u)

if [[ -z "${PREFIXES}" ]]; then
    echo "ERROR: No path prefixes found in the OpenAPI spec." >&2
    echo "The /v3/api-docs endpoint returned a spec with no paths." >&2
    exit 1
fi

echo ""
echo "Discovered prefixes:"
echo "${PREFIXES}" | while read -r prefix; do
    echo "  /${prefix}"
done

# --- Build the YAML paths array ---
PATHS_YAML=""
while read -r prefix; do
    PATHS_YAML="${PATHS_YAML}  - /${prefix}\n"
done <<< "${PREFIXES}"

# --- Show diff of current vs new prefixes ---
echo ""
CURRENT_PREFIXES=$(yq '.services[0].routes[0].paths[]' "${KONG_FILE}" 2>/dev/null | sort -u || echo "")
echo "--- Current routes ---"
if [[ -n "${CURRENT_PREFIXES}" ]]; then
    echo "${CURRENT_PREFIXES}"
else
    echo "  (none)"
fi

echo ""
echo "--- New routes ---"
echo "${PREFIXES}" | while read -r prefix; do echo "/${prefix}"; done

# Show added/removed
ADDED=$(comm -13 <(echo "${CURRENT_PREFIXES}" | sort) <(echo "${PREFIXES}" | sed 's|^|/|' | sort) 2>/dev/null || true)
REMOVED=$(comm -23 <(echo "${CURRENT_PREFIXES}" | sort) <(echo "${PREFIXES}" | sed 's|^|/|' | sort) 2>/dev/null || true)

if [[ -n "${ADDED}" ]]; then
    echo ""
    echo "++ Added:"
    echo "${ADDED}" | while read -r r; do echo "  ${r}"; done
fi

if [[ -n "${REMOVED}" ]]; then
    echo ""
    echo "-- Removed:"
    echo "${REMOVED}" | while read -r r; do echo "  ${r}"; done
fi

# --- Update kong.yml ---
echo ""
echo "Updating ${KONG_FILE} ..."

# Build a JSON array of the new paths for yq
PATHS_JSON=$(echo "${PREFIXES}" | jq -R -s 'split("\n") | map(select(length > 0) | "/\(.)")')

# Update only the routes paths — leave consumers and plugins untouched
yq -i ".services[0].routes[0].paths = ${PATHS_JSON}" "${KONG_FILE}"

# --- Validate ---
if yq '.' "${KONG_FILE}" > /dev/null 2>&1; then
    echo "Validation: kong.yml is valid YAML."
else
    echo "ERROR: kong.yml failed YAML validation after update!" >&2
    exit 1
fi

echo ""
echo "Done. Review the changes in ${KONG_FILE} before deploying."
echo "Consumers and plugins were NOT modified."
