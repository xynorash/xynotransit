#!/usr/bin/env bash
# Load a backup into a database you name.
#
#   scripts/restore.sh backups/xynotransit-20260131-020000.dump xynotransit_restored
#   scripts/restore.sh backups/xynotransit-20260131-020000.dump xynotransit --force
#
# * The database is created when it does not exist.
# * A database that already holds tables is REFUSED unless you add --force. With --force its
#   public schema is dropped first, so everything in it is replaced by the backup.
# * There is no default target, so a restore can never hit the live database by accident.
#   To restore over the live one, stop the api first (docker compose stop api), run with --force,
#   then start it again.
# * Prints the row count of every table when it is done.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

force=0; args=()
for a in "$@"; do
  case $a in
    --force) force=1 ;;
    -*) echo "unknown option $a" >&2; exit 2 ;;
    *) args+=("$a") ;;
  esac
done
if (( ${#args[@]} != 2 )); then
  echo "usage: restore.sh <backup.dump> <database> [--force]" >&2
  exit 2
fi
dump=${args[0]}; target=${args[1]}
[[ -r $dump ]] || { echo "cannot read $dump" >&2; exit 1; }
[[ $target =~ ^[A-Za-z0-9_]+$ ]] || { echo "database name: letters, digits and _ only" >&2; exit 2; }
xt_tool pg_restore --list < "$dump" > /dev/null || { echo "$dump is not a readable backup" >&2; exit 1; }

if db_exists "$target"; then
  tables=$(psql_val "$target" -c "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
  if (( tables > 0 )); then
    if (( force == 0 )); then
      echo "REFUSED: $target already has $tables table(s). Use --force to replace everything in it." >&2
      exit 1
    fi
    echo "restore: --force, dropping the public schema of $target"
    psql_db "$target" -c "drop schema public cascade; create schema public;" > /dev/null
  fi
else
  db_create "$target"
fi

xt_tool pg_restore --no-owner --exit-on-error -d "$target" < "$dump"
echo "restore: loaded $(basename "$dump") into $target"
row_counts "$target"
