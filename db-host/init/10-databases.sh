#!/bin/bash
# Runs once on first Postgres init (docker-entrypoint-initdb.d). Creates one
# role + database per tenant, with passwords injected from the container env
# (set from db-host/.env). Idempotent-safe via DO blocks.
#
#   acs_db  / acs_user   — agri-catalogue-service
#   oas_db  / oas_user   — org-user-notification-services
#   kong    / kong_user  — Kong gateway's own datastore (DB mode)
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'acs_user') THEN
    CREATE ROLE acs_user LOGIN PASSWORD '${ACS_DB_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'oas_user') THEN
    CREATE ROLE oas_user LOGIN PASSWORD '${OAS_DB_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kong_user') THEN
    CREATE ROLE kong_user LOGIN PASSWORD '${KONG_DB_PASSWORD}';
  END IF;
END \$\$;
SQL

# CREATE DATABASE cannot run inside a transaction/DO block; guard with a check.
create_db() {
  local db="$1" owner="$2"
  if ! psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" --username "$POSTGRES_USER" | grep -q 1; then
    createdb --username "$POSTGRES_USER" --owner "$owner" "$db"
    echo "created database ${db} (owner ${owner})"
  else
    echo "database ${db} already exists"
  fi
}

create_db acs_db  acs_user
create_db oas_db  oas_user
create_db kong    kong_user

echo "OAS databases initialised."
