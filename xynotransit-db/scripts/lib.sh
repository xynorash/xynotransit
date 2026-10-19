# Shared helpers for the maintenance scripts (source this file, do not run it).
#
# By default every Postgres tool runs INSIDE the database container, so the host needs only Docker:
#   DB_CONTAINER   container name (default xynotransit-db-db-1)
#   PGUSER         database user (default xynotransit)
#   PGDATABASE     the live database (default xynotransit)
# With XT_HOST_TOOLS=1 the tools psql, pg_dump, pg_restore on the host are used instead and the
# standard PGHOST, PGPORT, PGUSER, PGPASSWORD variables apply.

DB_CONTAINER=${DB_CONTAINER:-xynotransit-db-db-1}
PGUSER=${PGUSER:-xynotransit}
PGDATABASE=${PGDATABASE:-xynotransit}
XT_DB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INITDB_DIR=${INITDB_DIR:-$XT_DB_DIR/initdb}

xt_tool() { # tool args...  (stdin is passed through)
  local tool=$1; shift
  if [[ ${XT_HOST_TOOLS:-0} == 1 ]]; then
    PGOPTIONS="-c client_min_messages=warning" "$tool" "$@"
  else
    docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$DB_CONTAINER" "$tool" -U "$PGUSER" "$@"
  fi
}
psql_db() { local db=$1; shift; xt_tool psql -v ON_ERROR_STOP=1 -X -q -d "$db" "$@"; }
# One value, no headers, no alignment.
psql_val() { local db=$1; shift; xt_tool psql -v ON_ERROR_STOP=1 -X -q -At -d "$db" "$@"; }

db_exists() { [[ $(psql_val postgres -c "select 1 from pg_database where datname = '$1'") == 1 ]]; }
db_create() { psql_db postgres -c "create database \"$1\""; }
db_drop() { psql_db postgres -c "drop database if exists \"$1\" with (force)" >/dev/null; }

# Rows per table in the public schema, "table count" lines, sorted.
row_counts() {
  local db=$1 t
  for t in $(psql_val "$db" -c "select tablename from pg_tables where schemaname = 'public' order by 1"); do
    echo "$t $(psql_val "$db" -c "select count(*) from \"$t\"")"
  done
}

# Apply one initdb file through stdin (works with the container, where /initdb may be older).
apply_sql_file() { psql_db "$1" -f - < "$2" >/dev/null; }
