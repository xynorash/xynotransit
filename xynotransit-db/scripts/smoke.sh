#!/usr/bin/env bash
# End to end smoke test of a RUNNING stack, through nginx like a browser would.
# Signs in as the bootstrap manager through Mailpit, builds a tiny catalog, sends a
# report as an employee, generates a deck and checks the summary.
#
#   scripts/smoke.sh [base_url] [mailpit_url]
#
# Repeatable: every run uses random names and a random far-future period (2090 to 2100), and at the
# end it deactivates what it created through the API and, when the database container is
# reachable, removes those rows too (SMOKE_PURGE=0 skips that). Two runs in a row both pass.
#   SMOKE_MANAGER   default: BOOTSTRAP_CONTROLLER_EMAIL from the stack's .env, else
#                   smoke.manager@xynotransit.example (which must then be a manager already)
#   SMOKE_EMPLOYEE  default: a random smoke.employee.<n>@xynotransit.example (created by the run)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_MANAGER=""
if [ -f "$HERE/../.env" ]; then
  ENV_MANAGER=$(sed -n 's/^BOOTSTRAP_CONTROLLER_EMAIL=//p' "$HERE/../.env" | tail -1 | tr -d '\r"' | xargs || true)
fi

BASE=${1:-http://127.0.0.1:8080}
MAIL=${2:-http://127.0.0.1:8025}
API="$BASE/api"
MANAGER=${SMOKE_MANAGER:-${ENV_MANAGER:-smoke.manager@xynotransit.example}}
RUN=$(date +%s)$RANDOM
EMPLOYEE=${SMOKE_EMPLOYEE:-smoke.employee.$RUN@xynotransit.example}
# Two different months between 2090 and 2100 (the API accepts years up to 2100).
rand_month() { printf '%d-%02d-01' $((2090 + RANDOM % 11)) $((1 + RANDOM % 12)); }
PERIOD_START=$(rand_month)
EMPTY_START=$(rand_month)
while [ "$EMPTY_START" = "$PERIOD_START" ]; do EMPTY_START=$(rand_month); done
TEAM="" PERSON="" SEAT="" PERIOD="" EMPTY="" M=""

cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [ -n "$M" ]; then
    local h=(-H "authorization: Bearer $M" -H 'content-type: application/json')
    [ -n "$SEAT" ] && curl -fsS -X PATCH "$API/assignments/$SEAT" "${h[@]}" -d '{"active":false}' -o /dev/null
    [ -n "$PERSON" ] && curl -fsS -X PATCH "$API/persons/$PERSON" "${h[@]}" -d '{"active":false}' -o /dev/null
  fi
  if [ "${SMOKE_PURGE:-1}" = 1 ] && [ -n "$PERSON$TEAM$PERIOD$EMPTY" ] && . "$HERE/lib.sh" 2>/dev/null \
     && docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
    local q="set client_min_messages = warning; begin; set local xt.allow_deck_delete = 'on';"
    for p in $PERIOD $EMPTY; do q+=" delete from deck_run where period_id = '$p';"; done
    [ -n "$SEAT" ] && q+=" delete from report where assignment_id = '$SEAT'; delete from assignment where id = '$SEAT';"
    for p in $PERIOD $EMPTY; do
      q+=" delete from deck_text where period_id = '$p'; delete from period p where p.id = '$p' and not exists (select 1 from report r where r.period_id = p.id);"
    done
    [ -n "$PERSON" ] && q+=" delete from login_token where person_id = '$PERSON'; delete from person where id = '$PERSON';"
    [ -n "$TEAM" ] && q+=" delete from team where id = $TEAM and not exists (select 1 from assignment where team_id = $TEAM);"
    q+=" commit;"
    psql_db "$PGDATABASE" -c "$q" >/dev/null 2>&1 || echo "note: smoke rows were deactivated but not purged from the database" >&2
  fi
  exit $rc
}
trap cleanup EXIT

fail() { echo "SMOKE FAILED: $*" >&2; exit 1; }
j() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
step() { echo "== $*"; }

wait_for() { # url, label
  for _ in $(seq 1 90); do
    if curl -fsS "$1" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail "$2 did not come up ($1)"
}

# Magic link: request, read the newest mail for $1, trade the token for a JWT.
login() {
  local email=$1 before after id token
  before=$(curl -fsS "$MAIL/api/v1/messages" | j "len(d['messages'])")
  curl -fsS -X POST "$API/auth/magic-link" -H 'content-type: application/json' \
    -d "{\"email\":\"$email\"}" -o /dev/null || fail "magic link request for $email"
  for _ in $(seq 1 30); do
    after=$(curl -fsS "$MAIL/api/v1/messages" | j "len(d['messages'])")
    [ "$after" -gt "$before" ] && break
    sleep 1
  done
  [ "$after" -gt "$before" ] || fail "no email arrived for $email"
  id=$(curl -fsS "$MAIL/api/v1/search?query=to:$email" | j "d['messages'][0]['ID']")
  token=$(curl -fsS "$MAIL/api/v1/message/$id" | python3 -c "import sys,json,re; print(re.findall(r'token=([A-Za-z0-9_-]+)', json.load(sys.stdin)['Text'])[0])")
  curl -fsS -X POST "$API/auth/verify" -H 'content-type: application/json' \
    -d "{\"token\":\"$token\"}" | j "d['access_token']"
}

step "stack is up"
wait_for "$API/health" "api"
wait_for "$MAIL/api/v1/messages" "mailpit"
curl -fsS "$BASE/" | grep -qi "<title>" || fail "web page has no title"
curl -fsS "$BASE/manager" | grep -qi "<title>" || fail "SPA fallback for /manager"

step "sign in as the manager (bootstrap)"
# The sign-in limit is 5 requests per address per hour. When the database container is reachable,
# forget the manager's earlier requests so repeated runs keep passing (SMOKE_PURGE=0 skips this).
if [ "${SMOKE_PURGE:-1}" = 1 ] && ( . "$HERE/lib.sh" && docker inspect "$DB_CONTAINER" >/dev/null 2>&1 ); then
  ( . "$HERE/lib.sh"
    psql_db "$PGDATABASE" -c "delete from login_attempt where email = lower('$MANAGER'); delete from login_token where person_id in (select id from person where lower(email) = lower('$MANAGER'))" >/dev/null 2>&1 ) || true
fi
M=$(login "$MANAGER")
[ "$(curl -fsS "$API/me" -H "authorization: Bearer $M" | j "d['role']")" = controller ] || fail "manager role"

step "no one else can read anything without a token"
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/catalog")
[ "$code" = 401 ] || fail "catalog without token returned $code"

H=(-H "authorization: Bearer $M" -H 'content-type: application/json')
step "manager builds a team, a person, a seat with 2 counts and 2 targets"
TEAM=$(curl -fsS -X POST "$API/teams" "${H[@]}" -d "{\"name\":\"Smoke team $RUN\"}" | j "d['id']")
PERSON=$(curl -fsS -X POST "$API/persons" "${H[@]}" -d "{\"full_name\":\"Smoke Employee $RUN\",\"email\":\"$EMPLOYEE\",\"app_role\":\"contributor\"}" | j "d['id']")
SEAT=$(curl -fsS -X POST "$API/assignments" "${H[@]}" -d "{\"person_id\":\"$PERSON\",\"team_id\":\"$TEAM\",\"role_title\":\"Tester\"}" | j "d['id']")
DEF=$(curl -fsS -X PUT "$API/assignments/$SEAT/definitions" "${H[@]}" \
  -d '{"metrics":[{"label":"Sea"},{"label":"Air"}],"kpis":[{"text":"All files on time"},{"text":"No errors"}]}')
echo "$DEF" | j "len(d['metrics'])" | grep -qx 2 || fail "definitions"

step "employee signs in and sends the report"
E=$(login "$EMPLOYEE")
EH=(-H "authorization: Bearer $E" -H 'content-type: application/json')
PERIOD=$(curl -fsS -X POST "$API/periods/ensure" "${EH[@]}" -d "{\"start_month\":\"$PERIOD_START\"}" | j "d['id']")
BODY=$(echo "$DEF" | python3 -c "
import sys,json
a=json.load(sys.stdin)
vals=[{'metric_def_id':m['id'],'month_offset':o,'value':10+o} for m in a['metrics'] for o in range(3)]
kpis=[{'kpi_def_id':k['id'],'status':'met','comment':'Smoke comment'} for k in a['kpis']]
print(json.dumps({'reporter':{'name':'Smoke Reporter','country':'Smokeland','role':'Tester'},'values':vals,'kpis':kpis,'notes':[{'kind':'well','position':1,'text':'Smoke test note'}]}))")
curl -fsS -X PUT "$API/periods/$PERIOD/reports/$SEAT" "${EH[@]}" -d "$BODY" | j "d['status']" | grep -qx submitted || fail "send report"
curl -fsS "$API/periods/$PERIOD/deck-text" -H "authorization: Bearer $E" -o /dev/null || fail "employee must read the deck words"
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/periods/$PERIOD/deck" -H "authorization: Bearer $E")
[ "$code" = 403 ] || fail "employee must not read the deck (got $code)"

step "manager sets the slide words, generates the deck, reads the summary"
curl -fsS -X PUT "$API/periods/$PERIOD/deck-text" "${H[@]}" \
  -d '{"settings":{"title":"Smoke Test Review"}}' -o /dev/null || fail "set deck words"
curl -fsS -X POST "$API/periods/$PERIOD/deck" "${H[@]}" -d '{}' | j "d['included_count']" | grep -qx 1 || fail "generate deck"
curl -fsS "$API/summary?period_id=$PERIOD" -H "authorization: Bearer $M" | j "d['submitted']" | grep -qx 1 || fail "summary"

step "a deck works with no submitted reports at all"
EMPTY=$(curl -fsS -X POST "$API/periods/ensure" "${H[@]}" -d "{\"start_month\":\"$EMPTY_START\"}" | j "d['id']")
curl -fsS -X POST "$API/periods/$EMPTY/deck" "${H[@]}" -d '{}' | j "d['included_count']" | grep -qx 0 || fail "deck with zero reports"

step "the sign-in limit answers the same for an address that does not exist"
ghost="ghost.$RANDOM$RANDOM@xynotransit.example"
for i in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/magic-link" -H 'content-type: application/json' -d "{\"email\":\"$ghost\"}")
  [ "$code" = 202 ] || fail "request $i for unknown address returned $code"
done
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/auth/magic-link" -H 'content-type: application/json' -d "{\"email\":\"$ghost\"}")
[ "$code" = 429 ] || fail "6th request for unknown address returned $code, expected 429"

echo "SMOKE OK"
