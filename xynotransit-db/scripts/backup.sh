#!/usr/bin/env bash
# Dump the database to a timestamped file and keep the newest 14.
#
#   scripts/backup.sh                  -> backups/xynotransit-20260131-020000.dump
#
# BACKUP_DIR   where to write (default: backups/ next to the scripts folder)
# BACKUP_KEEP  how many dumps to keep (default 14)
# PGDATABASE   what to dump (default xynotransit)
#
# The dump is pg_dump's custom format: compressed, and restore.sh can load all of it or parts of it.
# It is written to a .part file first and renamed only when pg_restore can read its table of
# contents, so a failed run never leaves a half file that looks like a backup.
#
# Daily at 02:00 from cron (one line, edit the path):
#   0 2 * * * cd /path/to/xynotransit/xynotransit-db && ./scripts/backup.sh >> backups/backup.log 2>&1
set -euo pipefail
. "$(dirname "$0")/lib.sh"

dir=${BACKUP_DIR:-$XT_DB_DIR/backups}
keep=${BACKUP_KEEP:-14}
[[ $keep =~ ^[0-9]+$ && $keep -ge 1 ]] || { echo "BACKUP_KEEP must be a number, 1 or more" >&2; exit 2; }
mkdir -p "$dir"
# Nothing in this folder is ever committed.
[[ -e $dir/.gitignore ]] || printf '*\n!.gitignore\n' > "$dir/.gitignore"

db_exists "$PGDATABASE" || { echo "database $PGDATABASE does not exist" >&2; exit 1; }

stamp=$(date +%Y%m%d-%H%M%S)
file=$dir/$PGDATABASE-$stamp.dump
part=$file.part
trap 'rm -f "$part"' EXIT

xt_tool pg_dump -Fc --no-owner "$PGDATABASE" > "$part"
[[ -s $part ]] || { echo "backup is empty" >&2; exit 1; }
xt_tool pg_restore --list < "$part" > /dev/null || { echo "backup cannot be read back" >&2; exit 1; }
mv "$part" "$file"
trap - EXIT
echo "backup: $file ($(du -h "$file" | cut -f1))"

# Keep the newest $keep (names sort by time).
mapfile -t all < <(ls -1 "$dir"/"$PGDATABASE"-*.dump 2>/dev/null | sort)
if (( ${#all[@]} > keep )); then
  for old in "${all[@]:0:${#all[@]}-keep}"; do
    rm -f -- "$old"
    echo "backup: removed old $(basename "$old")"
  done
fi
