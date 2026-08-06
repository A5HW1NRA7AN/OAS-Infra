#!/usr/bin/env bash
# flush-databases.sh
# ─────────────────────────────────────────────────────────────────────────────
# DESTRUCTIVE. Flushes catalogue DATA on the DB host so it can be re-ingested via
# bulk upload — SCOPED per service, so you flush only what you choose. Works for
# every current and future service: it reads the `catalogues:` list from each
# services/<svc>.config.yaml (the single source of truth), so a new service or
# catalogue needs no change here — just its config entry.
#
# Per selected service, for each of its catalogues <c>:
#   • PostgreSQL    : TRUNCATE table <c>       (in that service's database; schema KEPT)
#   • Elasticsearch : DELETE index <c>_index   (app recreates it on the next write)
#   • Redis         : DEL keys <c>-*           (record cache; NO FLUSHALL — other
#                                               services' cache is untouched)
# App pods are NOT touched — they repopulate on your next bulk upload.
#
# Because the scope is the config's catalogue list (not "every table in the DB"),
# stale/orphaned tables and other services sharing the same ES/Redis are safe.
#
# Usage:
#   scripts/flush-databases.sh --all              # flush every service
#   scripts/flush-databases.sh --org              # flush one (prefix-matches the service name)
#   scripts/flush-databases.sh --org --agri       # flush several
#   scripts/flush-databases.sh --all --yes        # skip the typed confirmation
#   scripts/flush-databases.sh --list             # show services / dbs / catalogues, then exit
#
# Selectors match by prefix on the service name, so --org == org-user-notification-services,
# --agri == agri-catalogue. Reaches the private DB host through the bastion using
# terraform's env.sh (BASTION_IP / DB_HOST_IP / KEY_PATH). Requires the oas-uat env.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$REPO_ROOT/terraform/environments/oas-uat"

# ── per-config parsers (block-aware for the nested service:/database: names) ──
stem_of() { local b; b="$(basename "$1")"; echo "${b%.config.yaml}"; }
svc_of()  { awk '/^service:/{f=1;next} f&&/name:/{print $2;exit}'  "$1"; }
db_of()   { awk '/^database:/{f=1;next} f&&/name:/{print $2;exit}' "$1"; }
cats_of() { grep -E '^catalogues:' "$1" | sed -E 's/^catalogues:[[:space:]]*\[(.*)\].*/\1/' | tr ',' ' '; }
lc()      { tr '[:upper:]' '[:lower:]'; }

shopt -s nullglob
CFGS=( "$REPO_ROOT"/services/*.config.yaml )
[ ${#CFGS[@]} -gt 0 ] || { echo "ERROR: no services/*.config.yaml found." >&2; exit 1; }

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_services() {
  echo "Discovered services (selector = any prefix of the name):"
  for c in "${CFGS[@]}"; do
    printf "  %-32s db=%-8s catalogues: %s\n" "$(stem_of "$c")" "$(db_of "$c")" "$(cats_of "$c" | xargs echo)"
  done
}

# ── parse args ───────────────────────────────────────────────────────────────
ASSUME_YES=0; ALL=0; DO_LIST=0
declare -a SELECTED=()
[ $# -gt 0 ] || { usage; exit 1; }
for arg in "$@"; do
  t="${arg#-}"; t="${t#-}"                       # strip one or two leading dashes
  case "$(echo "$t" | lc)" in
    yes|y)  ASSUME_YES=1 ;;
    all)    ALL=1 ;;
    list)   DO_LIST=1 ;;
    "")     ;;
    *)      matched=0
            tl="$(echo "$t" | lc)"
            for c in "${CFGS[@]}"; do
              s="$(stem_of "$c" | lc)"; v="$(svc_of "$c" | lc)"
              if [[ "$s" == "$tl"* || "$v" == "$tl"* ]]; then SELECTED+=("$c"); matched=1; fi
            done
            [ "$matched" -eq 1 ] || { echo "ERROR: no service matches '$arg'." >&2; list_services >&2; exit 1; } ;;
  esac
done

if [ "$DO_LIST" -eq 1 ]; then list_services; exit 0; fi
[ "$ALL" -eq 1 ] && SELECTED=( "${CFGS[@]}" )
[ ${#SELECTED[@]} -gt 0 ] || { echo "ERROR: nothing selected — pass --all or a service selector." >&2; list_services >&2; exit 1; }

# de-duplicate SELECTED (a token may match several / overlap)
declare -a SVC=()
for c in "${SELECTED[@]}"; do
  seen=0; for e in "${SVC[@]:-}"; do [ "$e" = "$c" ] && seen=1; done
  [ "$seen" -eq 0 ] && SVC+=("$c")
done

# ── env (bastion / db host / key) ────────────────────────────────────────────
# shellcheck disable=SC1091
[ -f "$ENV_DIR/env.sh" ] && source "$ENV_DIR/env.sh" \
  || { echo "ERROR: $ENV_DIR/env.sh not found (run terraform first)." >&2; exit 1; }
: "${BASTION_IP:?not set in env.sh}"; : "${DB_HOST_IP:?not set in env.sh}"; : "${KEY_PATH:?not set in env.sh}"

# ── confirm ──────────────────────────────────────────────────────────────────
echo "About to PERMANENTLY FLUSH catalogue data on the DB host (${DB_HOST_IP}):"
for c in "${SVC[@]}"; do
  cats="$(cats_of "$c" | xargs echo)"
  [ -n "$cats" ] || { echo "ERROR: $(basename "$c") has no 'catalogues:' list — add one." >&2; exit 1; }
  printf "  • %-32s db=%-8s catalogues: %s\n" "$(stem_of "$c")" "$(db_of "$c")" "$cats"
done
echo "  (Postgres tables TRUNCATEd, ES <c>_index deleted, Redis <c>-* deleted; schema kept.)"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Type FLUSH to proceed (anything else aborts): " ans
  [ "$ans" = "FLUSH" ] || { echo "Aborted — nothing was changed."; exit 1; }
fi

# ── flush each selected service on the DB host (via bastion) ──────────────────
for c in "${SVC[@]}"; do
  db="$(db_of "$c")"; cats="$(cats_of "$c")"
  echo "==> Flushing $(stem_of "$c") (db=$db) via bastion -> ${DB_HOST_IP} ..."
  # Runs ON the DB host. Positional args: $1=db, $2..=catalogue names.
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
      "ubuntu@$DB_HOST_IP" "bash -s $db $cats" <<'REMOTE'
set -e
db="$1"; shift
[ "$#" -gt 0 ] || { echo "  (no catalogues to flush)"; exit 0; }

# Postgres: TRUNCATE only the listed catalogue tables that actually exist.
# quote_ident() safely quotes reserved words (e.g. "user").
inlist=""; for cse in "$@"; do inlist="${inlist:+$inlist,}'$cse'"; done
echo "  PostgreSQL[$db]: truncating [$*] (schema kept)"
stmt=$(docker exec oas-postgres psql -U postgres -d "$db" -tAc \
  "SELECT 'TRUNCATE TABLE '||string_agg(quote_ident(tablename), ', ')||' RESTART IDENTITY CASCADE' \
   FROM pg_tables WHERE schemaname='public' AND tablename IN ($inlist)")
if [ -n "$stmt" ]; then
  docker exec oas-postgres psql -U postgres -d "$db" -c "$stmt" >/dev/null
  echo "    -> $stmt"
else
  echo "    -> (none of [$*] exist in $db)"
fi

echo "  Elasticsearch: deleting <catalogue>_index"
for cse in "$@"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "localhost:9200/${cse}_index")
  case "$code" in
    200) echo "    -> deleted ${cse}_index" ;;
    404) echo "    -> ${cse}_index absent (skip)" ;;
    *)   echo "    -> ${cse}_index: HTTP $code" ;;
  esac
done

echo "  Redis: deleting <catalogue>-* keys (no FLUSHALL)"
for cse in "$@"; do
  n=$(docker exec oas-redis sh -c "redis-cli --scan --pattern '${cse}-*' | wc -l" | tr -d '[:space:]')
  if [ "${n:-0}" -gt 0 ]; then
    docker exec oas-redis sh -c "redis-cli --scan --pattern '${cse}-*' | xargs -r -n 200 redis-cli DEL" >/dev/null 2>&1 || true
  fi
  echo "    -> ${cse}-* (${n:-0} key(s))"
done
REMOTE
done

echo "==> Flush complete. Re-ingest via your bulk uploads."
