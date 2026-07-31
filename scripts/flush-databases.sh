#!/usr/bin/env bash
# flush-databases.sh
# ─────────────────────────────────────────────────────────────────────────────
# DESTRUCTIVE. Wipes all catalogue DATA on the DB host so it can be re-ingested
# via bulk upload — for BOTH services (agri + org):
#   • PostgreSQL : TRUNCATE every table in each app database (schema is KEPT).
#   • Elasticsearch : delete every catalogue index (non-system).
#   • Redis : FLUSHALL (search-result cache).
#
# The application pods are NOT touched — they keep running and simply repopulate
# on your next bulk upload. Schema is preserved (tables are truncated, not
# dropped; ES indices are recreated by the app on the next write).
#
# Run this ONLY when no one is mid-work — it clears everyone's data at once.
#
# Usage:
#   scripts/flush-databases.sh          # asks you to type FLUSH to confirm
#   scripts/flush-databases.sh --yes    # skip the prompt (automation)
#
# Reaches the private DB host through the bastion, using terraform's env.sh
# (BASTION_IP / DB_HOST_IP / KEY_PATH). Requires: the oas-uat env provisioned.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ASSUME_YES=0
case "${1:-}" in
  -y|--yes) ASSUME_YES=1 ;;
  "")       ;;
  *)        echo "Usage: $0 [--yes]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/oas-uat"
# shellcheck disable=SC1091
[ -f "$ENV_DIR/env.sh" ] && source "$ENV_DIR/env.sh" \
  || { echo "ERROR: $ENV_DIR/env.sh not found (run terraform first)." >&2; exit 1; }

# Discover the Postgres databases from the service configs (single source of truth):
# the first `name:` after each `database:` block.
DBS=$(awk '/^database:/{f=1;next} f&&/name:/{print $2;f=0}' "$REPO_ROOT"/services/*.config.yaml | sort -u | tr '\n' ' ')
[ -n "${DBS// }" ] || { echo "ERROR: no database names found in services/*.config.yaml" >&2; exit 1; }

cat <<BANNER
About to PERMANENTLY FLUSH all catalogue data on the DB host (${DB_HOST_IP}):
  PostgreSQL    : TRUNCATE all tables in ->${DBS:+ }$DBS
  Elasticsearch : delete all catalogue indices (non-system)
  Redis         : FLUSHALL (cache)
Schema is preserved; the running apps repopulate on your next bulk upload.
BANNER

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Type FLUSH to proceed (anything else aborts): " ans
  [ "$ans" = "FLUSH" ] || { echo "Aborted — nothing was changed."; exit 1; }
fi

echo "==> Flushing via the bastion -> DB host ${DB_HOST_IP} ..."
# All the work runs ON the DB host (single quoting level) to avoid nested-quote
# hell; the DB names are passed as positional args to the remote shell.
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
    "ubuntu@$DB_HOST_IP" "bash -s $DBS" <<'REMOTE'
set -e
for db in "$@"; do
  echo "  PostgreSQL: flushing '$db'"
  stmt=$(docker exec oas-postgres psql -U postgres -d "$db" -tAc \
    "SELECT 'TRUNCATE TABLE ' || string_agg(quote_ident(tablename), ', ') || ' RESTART IDENTITY CASCADE' \
     FROM pg_tables WHERE schemaname='public'")
  if [ -n "$stmt" ]; then
    docker exec oas-postgres psql -U postgres -d "$db" -c "$stmt" >/dev/null
    echo "    -> all tables truncated"
  else
    echo "    -> (no tables yet)"
  fi
done

echo "  Elasticsearch: deleting catalogue indices"
for idx in $(curl -s "localhost:9200/_cat/indices?h=index" | grep -vE '^\.' || true); do
  curl -s -X DELETE "localhost:9200/$idx" >/dev/null && echo "    -> deleted $idx"
done

echo "  Redis: FLUSHALL"
docker exec oas-redis redis-cli FLUSHALL >/dev/null && echo "    -> cache cleared"
REMOTE

echo "==> Flush complete. Re-ingest via your bulk uploads."
