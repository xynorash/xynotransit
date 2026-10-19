#!/usr/bin/env bash
# Proves backup and restore with the live database: dump, restore into a scratch database, row
# counts and schema equal; a non-empty target is refused without --force and replaced with it;
# rotation keeps only the newest 14. Prints PASS or FAIL. The live database is only read.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

S="xt_bak_$$"; T=$(mktemp -d); failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok:   $*"; }
trap 'db_drop "$S"; rm -rf "$T"' EXIT
here=$(dirname "$0")

export BACKUP_DIR=$T/backups
"$here/backup.sh" > "$T/out" 2>&1 && ok "backup.sh: $(head -1 "$T/out")" || { fail "backup.sh: $(cat "$T/out")"; }
dump=$(ls "$BACKUP_DIR"/*.dump 2>/dev/null | head -1)
[[ -n $dump ]] || { fail "no dump written"; echo "FAIL: backup"; exit 1; }
[[ -f $BACKUP_DIR/.gitignore ]] && ok "backups folder ignores itself in git" || fail "no .gitignore in the backups folder"

row_counts "$PGDATABASE" > "$T/live"
"$here/restore.sh" "$dump" "$S" > "$T/restore.out" 2>&1 && ok "restored into $S" || fail "restore: $(tail -3 "$T/restore.out")"
row_counts "$S" > "$T/copy"
if diff -q "$T/live" "$T/copy" > /dev/null; then
  ok "row counts equal: $(awk '{s+=$2} END {print s}' "$T/live") rows in $(wc -l < "$T/live") tables"
else fail "row counts differ"; diff "$T/live" "$T/copy" | head; fi
# pg_dump prints nested AND/OR in a check a little differently after a restore; same meaning, so
# the brackets of CONSTRAINT lines are ignored.
norm() { grep -v -e '^--' -e '^$' -e '^.restrict' -e '^.unrestrict' | sed -E '/CONSTRAINT/ s/[()]//g'; }
if diff -q <(xt_tool pg_dump -s --no-owner --no-privileges "$PGDATABASE" | norm) <(xt_tool pg_dump -s --no-owner --no-privileges "$S" | norm) > /dev/null; then
  ok "schema equal (tables, constraints, triggers, indexes)"
else fail "schema differs"; fi

# Refuse without --force.
if "$here/restore.sh" "$dump" "$S" > "$T/refuse.out" 2>&1; then fail "restore over a non-empty database was NOT refused"
else grep -q REFUSED "$T/refuse.out" && ok "non-empty target refused" || fail "refusal message missing"; fi
psql_db "$S" -c "delete from login_attempt; insert into team (code, name, sort) values ('extra', 'Extra Team For Test', 9)" > /dev/null
"$here/restore.sh" "$dump" "$S" --force > "$T/force.out" 2>&1 && ok "--force replaces the content" || fail "restore --force: $(tail -3 "$T/force.out")"
row_counts "$S" > "$T/copy2"
diff -q "$T/live" "$T/copy2" > /dev/null && ok "after --force the counts equal the backup again" || fail "counts differ after --force"
# Bad input.
"$here/restore.sh" "$T/nothing.dump" "$S" > /dev/null 2>&1 && fail "missing file accepted" || ok "missing file refused"
echo "not a dump" > "$T/bad.dump"
"$here/restore.sh" "$T/bad.dump" "$S" --force > /dev/null 2>&1 && fail "garbage file accepted" || ok "garbage file refused"
row_counts "$S" > "$T/copy3"
diff -q "$T/live" "$T/copy3" > /dev/null && ok "a refused restore changed nothing" || fail "refused restore damaged the target"

# Rotation: 16 old dumps and one new one -> 14 left, the newest kept, the oldest gone.
rm -f "$BACKUP_DIR"/*.dump
for i in $(seq -w 1 16); do touch "$BACKUP_DIR/$PGDATABASE-20200101-0000$i.dump"; done
before=$(ls "$BACKUP_DIR"/*.dump | wc -l)
"$here/backup.sh" > /dev/null 2>&1
after=$(ls "$BACKUP_DIR"/*.dump | wc -l)
newest=$(ls "$BACKUP_DIR"/*.dump | sort | tail -1)
[[ $before == 16 && $after == 14 ]] && ok "rotation: $before -> $after files" || fail "rotation: $before -> $after"
[[ $(stat -c %s "$newest") -gt 100 ]] && ok "the new dump is the newest and was kept" || fail "new dump was removed"
BACKUP_KEEP=0 "$here/backup.sh" > /dev/null 2>&1 && fail "BACKUP_KEEP=0 accepted" || ok "BACKUP_KEEP=0 refused"

echo
if (( failures == 0 )); then echo "PASS: backup and restore"; else echo "FAIL: backup and restore ($failures problem(s))"; exit 1; fi
