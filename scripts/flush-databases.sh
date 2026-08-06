#!/usr/bin/env bash
# flush-databases.sh
# ─────────────────────────────────────────────────────────────────────────────
# DESTRUCTIVE. Flushes catalogue DATA on the DB host so it can be re-ingested via
# bulk upload — at whatever granularity you choose: a single catalogue, a whole
# service, or everything. Config-driven: it reads the `catalogues:` list from each
# services/<svc>.config.yaml (the single source of truth), so new services /
# catalogues need no change here — just their config entry.
#
# For each catalogue <c> it flushes, in that catalogue's own database:
#   • PostgreSQL    : TRUNCATE table <c>       (schema KEPT)
#   • Elasticsearch : DELETE index <c>_index   (app recreates it on the next write)
#   • Redis         : DEL keys <c>-*           (record cache; NO FLUSHALL)
# App pods are NOT touched — they repopulate on your next bulk upload. Scope is
# always the exact catalogue(s) named, so other catalogues / services (and the
# shared ES/Redis) are never affected.
#
# Usage:
#   scripts/flush-databases.sh --list                 # show services / dbs / catalogues
#   scripts/flush-databases.sh --all                  # every catalogue of every service
#   scripts/flush-databases.sh --agri                 # a whole service (prefix-matches the name)
#   scripts/flush-databases.sh --cropvariety          # ONE catalogue (by name)
#   scripts/flush-databases.sh -c cropvariety -c seed # one or more catalogues (explicit flag)
#   scripts/flush-databases.sh --org --cropvariety    # mix: whole org + agri's cropvariety
#   scripts/flush-databases.sh --all --yes            # skip the typed FLUSH confirmation
#
# Selector rules: `--<name>` first tries a SERVICE (prefix match, e.g. --agri, --org),
# then falls back to an exact CATALOGUE name (e.g. --cropvariety). Use `-c <name>` /
# `--catalogue <name>` to force catalogue-level (handy when a name is also a service
# prefix, e.g. `-c org` flushes only the org catalogue, not org+user).
#
# Reaches the private DB host through the bastion using terraform's env.sh
# (BASTION_IP / DB_HOST_IP / KEY_PATH). Requires the oas-uat env provisioned.
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

usage() { sed -n '/^# Usage:/,/oas-uat env provisioned/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

list_services() {
  echo "Discovered services (selector = any prefix of the name; catalogues are flushable by name):"
  for c in "${CFGS[@]}"; do
    printf "  %-32s db=%-8s catalogues: %s\n" "$(stem_of "$c")" "$(db_of "$c")" "$(cats_of "$c" | xargs echo)"
  done
}

# Find the config that owns an exact catalogue name.
cfg_for_catalogue() {
  local want="$1" c cat
  for c in "${CFGS[@]}"; do
    for cat in $(cats_of "$c"); do [ "$cat" = "$want" ] && { echo "$c"; return 0; }; done
  done
  return 1
}

# ── selection state: WANT[cfg] = "*" (all catalogues) or " c1 c2 " (subset) ──
declare -A WANT=(); ORDER=(); ASSUME_YES=0; DO_LIST=0
want_full() { local c="$1"; [ -n "${WANT[$c]:-}" ] || ORDER+=("$c"); WANT[$c]="*"; }
want_cat()  { local c="$1" cat="$2"
  if [ -z "${WANT[$c]:-}" ]; then ORDER+=("$c"); WANT[$c]=" $cat "
  elif [ "${WANT[$c]}" != "*" ] && [[ "${WANT[$c]}" != *" $cat "* ]]; then WANT[$c]="${WANT[$c]}$cat "; fi
}
select_token() {   # a bare --<name>: service prefix first, else exact catalogue
  local tl; tl="$(printf '%s' "$1" | lc)"; local c hit=0
  for c in "${CFGS[@]}"; do
    if [[ "$(stem_of "$c" | lc)" == "$tl"* || "$(svc_of "$c" | lc)" == "$tl"* ]]; then want_full "$c"; hit=1; fi
  done
  [ $hit -eq 1 ] && return 0
  local cfg; cfg="$(cfg_for_catalogue "$tl")" && { want_cat "$cfg" "$tl"; return 0; }
  return 1
}

# ── parse args ───────────────────────────────────────────────────────────────
[ $# -gt 0 ] || { usage; exit 1; }
args=( "$@" ); i=0
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"; i=$((i+1))
  case "$arg" in
    -y|--yes)          ASSUME_YES=1 ;;
    --list)            DO_LIST=1 ;;
    --all)             for c in "${CFGS[@]}"; do want_full "$c"; done ;;
    -c|--catalogue)    cat="${args[$i]:-}"; i=$((i+1))
                       [ -n "$cat" ] || { echo "ERROR: $arg needs a catalogue name." >&2; exit 1; }
                       cfg="$(cfg_for_catalogue "$cat")" || { echo "ERROR: no service lists catalogue '$cat'." >&2; list_services >&2; exit 1; }
                       want_cat "$cfg" "$cat" ;;
    -c=*|--catalogue=*) cat="${arg#*=}"
                       cfg="$(cfg_for_catalogue "$cat")" || { echo "ERROR: no service lists catalogue '$cat'." >&2; list_services >&2; exit 1; }
                       want_cat "$cfg" "$cat" ;;
    -*)                t="${arg#-}"; t="${t#-}"
                       select_token "$t" || { echo "ERROR: '$arg' matches no service or catalogue." >&2; list_services >&2; exit 1; } ;;
    *)                 echo "ERROR: unexpected argument '$arg' (did you mean -c $arg ?)." >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$DO_LIST" -eq 1 ]; then list_services; exit 0; fi
[ ${#ORDER[@]} -gt 0 ] || { echo "ERROR: nothing selected — pass --all, a --service, or -c <catalogue>." >&2; list_services >&2; exit 1; }

# effective catalogue list for a config (all, or the chosen subset)
eff_cats() { local c="$1"; if [ "${WANT[$c]}" = "*" ]; then cats_of "$c"; else echo ${WANT[$c]}; fi; }

# ── env (bastion / db host / key) ────────────────────────────────────────────
# shellcheck disable=SC1091
[ -f "$ENV_DIR/env.sh" ] && source "$ENV_DIR/env.sh" \
  || { echo "ERROR: $ENV_DIR/env.sh not found (run terraform first)." >&2; exit 1; }
: "${BASTION_IP:?not set in env.sh}"; : "${DB_HOST_IP:?not set in env.sh}"; : "${KEY_PATH:?not set in env.sh}"

# ── confirm ──────────────────────────────────────────────────────────────────
echo "About to PERMANENTLY FLUSH these catalogues on the DB host (${DB_HOST_IP}):"
for c in "${ORDER[@]}"; do
  cats="$(eff_cats "$c" | xargs echo)"
  [ -n "$cats" ] || { echo "ERROR: $(basename "$c") has no 'catalogues:' list — add one." >&2; exit 1; }
  printf "  • %-32s db=%-8s -> %s\n" "$(stem_of "$c")" "$(db_of "$c")" "$cats"
done
echo "  (Postgres TRUNCATE <c>, ES delete <c>_index, Redis delete <c>-*; schema kept.)"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Type FLUSH to proceed (anything else aborts): " ans
  [ "$ans" = "FLUSH" ] || { echo "Aborted — nothing was changed."; exit 1; }
fi

# ── flush each selected (db, catalogues) group on the DB host (via bastion) ───
for c in "${ORDER[@]}"; do
  db="$(db_of "$c")"; cats="$(eff_cats "$c")"
  echo "==> Flushing [$(echo $cats)] in $db (service $(stem_of "$c")) via bastion -> ${DB_HOST_IP} ..."
  # Runs ON the DB host. Positional args: $1=db, $2..=catalogue names.
  ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ProxyCommand="ssh -W %h:%p -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$BASTION_IP" \
      "ubuntu@$DB_HOST_IP" "bash -s $db $cats" <<'REMOTE'
set -e
db="$1"; shift
[ "$#" -gt 0 ] || { echo "  (no catalogues to flush)"; exit 0; }

# Postgres: TRUNCATE only the named catalogue tables that actually exist.
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
