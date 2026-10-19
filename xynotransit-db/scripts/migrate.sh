#!/usr/bin/env bash
# Bring a database up to date with initdb/*.sql.
#
#   scripts/migrate.sh [database]        (default: PGDATABASE, "xynotransit")
#
# initdb/*.sql runs by itself only on the FIRST start of an empty volume. A database that lives on
# needs the newer files applied, and this does it:
#   * empty database            -> applies every file, 01 to the last.
#   * has the ledger            -> applies only the files not listed in schema_migration.
#   * old database, no ledger   -> 01 and 02 are assumed to be there; 03 onward are written to run
#                                  twice, so they are all applied (07 then creates the ledger).
# Safe to run any number of times. Prints what it did.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

db=${1:-$PGDATABASE}
db_exists "$db" || { echo "database $db does not exist" >&2; exit 1; }

files=("$INITDB_DIR"/*.sql)
has_team=$(psql_val "$db" -c "select to_regclass('public.team') is not null")
has_ledger=$(psql_val "$db" -c "select to_regclass('public.schema_migration') is not null")

applied=0
for f in "${files[@]}"; do
  name=$(basename "$f")
  if [[ $has_ledger == t ]]; then
    seen=$(psql_val "$db" -c "select 1 from schema_migration where file = '$name'")
    [[ $seen == 1 ]] && continue
  elif [[ $has_team == t && $name < 03 ]]; then
    continue
  fi
  echo "migrate: $name"
  apply_sql_file "$db" "$f"
  applied=$((applied + 1))
  # 07 creates the ledger; from then on the ledger decides.
  has_ledger=$(psql_val "$db" -c "select to_regclass('public.schema_migration') is not null")
done
echo "migrate: $applied file(s) applied to $db"
