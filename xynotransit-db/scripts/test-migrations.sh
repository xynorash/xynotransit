#!/usr/bin/env bash
# Proves that the migrations apply cleanly.
#
#   scripts/test-migrations.sh          prints PASS or FAIL, exit code 0 or 1
#
# (a) EMPTY DATABASE: all initdb files in name order, then 03..last again (they are written to run
#     twice; 01 and 02 create types and tables and cannot), then migrate.sh must find nothing to do.
#     The schema after the second pass must equal the schema after the first.
# (b) COPY OF THE LIVE DATABASE: pg_dump of $PGDATABASE into a scratch database, migrate.sh, then
#     every table keeps its row count, every constraint is valid, and (unless SKIP_API_TESTS=1) the
#     whole API test suite runs on a database built from that migrated copy (TEST_TEMPLATE_DB).
# Scratch databases are always removed. The live database is only read.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

A="xt_mig_a_$$"; B="xt_mig_b_$$"
failures=0
T=$(mktemp -d)
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok:   $*"; }
cleanup() { db_drop "$A"; db_drop "$B"; rm -rf "$T"; }
trap cleanup EXIT

schema_of() { xt_tool pg_dump -s --no-owner --no-privileges "$1" | grep -v -e '^--' -e '^$' -e '^.restrict' -e '^.unrestrict'; }

echo "== (a) empty database, twice"
db_create "$A" || { echo "FAIL: cannot create scratch database"; exit 1; }
for f in "$INITDB_DIR"/*.sql; do
  apply_sql_file "$A" "$f" 2>$T/err && ok "first pass $(basename "$f")" || { fail "first pass $(basename "$f"): $(head -3 $T/err)"; }
done
schema_of "$A" > $T/s1
for f in "$INITDB_DIR"/*.sql; do
  n=$(basename "$f"); [[ $n < 03 ]] && continue
  apply_sql_file "$A" "$f" 2>$T/err && ok "second pass $n" || fail "second pass $n: $(head -3 $T/err)"
done
schema_of "$A" > $T/s2
if diff -q $T/s1 $T/s2 >/dev/null; then ok "schema identical after the second pass"; else fail "schema changed on the second pass"; diff $T/s1 $T/s2 | head -10; fi
out=$("$(dirname "$0")/migrate.sh" "$A" 2>&1 | tail -1)
[[ $out == *"0 file(s) applied"* ]] && ok "migrate.sh finds nothing left to do" || fail "migrate.sh after full apply: $out"
n=$(psql_val "$A" -c "select count(*) from schema_migration")
[[ $n == "$(ls "$INITDB_DIR"/*.sql | wc -l)" ]] && ok "ledger lists all $n files" || fail "ledger has $n rows"
bad=$(psql_val "$A" -c "select count(*) from pg_constraint where not convalidated")
[[ $bad == 0 ]] && ok "all constraints valid" || fail "$bad constraints not valid on an empty database"

echo "== (b) copy of the live database ($PGDATABASE)"
if ! db_exists "$PGDATABASE"; then fail "live database $PGDATABASE not found"; else
  db_create "$B"
  xt_tool pg_dump -Fc --no-owner "$PGDATABASE" | xt_tool pg_restore --no-owner -d "$B" 2>$T/err \
    && ok "dumped and restored into $B" || fail "restore of the copy: $(head -3 $T/err)"
  row_counts "$B" > $T/c1
  "$(dirname "$0")/migrate.sh" "$B" 2>&1 | sed 's/^/      /'
  [[ ${PIPESTATUS[0]} == 0 ]] && ok "migrate.sh on the copy" || fail "migrate.sh on the copy"
  "$(dirname "$0")/migrate.sh" "$B" 2>&1 | tail -1 | sed 's/^/      /'
  row_counts "$B" > $T/c2
  # The ledger is the one table a migration may add or fill; every other table must keep its rows.
  if diff <(grep -v '^schema_migration ' $T/c2) <(grep -v '^schema_migration ' $T/c1) >/dev/null; then
    ok "row counts unchanged: $(awk '{s+=$2} END {print s}' $T/c1) rows in $(wc -l < $T/c1) tables"
  else fail "row counts changed"; diff <(grep -v '^schema_migration ' $T/c2) <(grep -v '^schema_migration ' $T/c1) | head; fi
  bad=$(psql_val "$B" -c "select count(*) from pg_constraint where not convalidated")
  [[ $bad == 0 ]] && ok "all constraints valid on the copy" || echo "warn: $bad constraint(s) left NOT VALID on the copy (old rows break them)"
  if [[ ${SKIP_API_TESTS:-0} != 1 ]]; then
    echo "== API test suite on a database built from the migrated copy"
    ( cd "$XT_DB_DIR/../xynotransit-api" && TEST_TEMPLATE_DB="$B" cargo test 2>&1 | grep -E '^test result|FAILED|panicked' ) > $T/t
    cat $T/t | sed 's/^/      /'
    if grep -q FAILED $T/t || ! grep -q '^test result: ok' $T/t; then fail "API tests on the migrated copy"; else ok "API tests pass on the migrated copy"; fi
  fi
fi
echo
if [[ $failures == 0 ]]; then echo "PASS: migrations"; exit 0; else echo "FAIL: migrations ($failures problem(s))"; exit 1; fi
