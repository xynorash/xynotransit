#!/usr/bin/env bash
# End to end smoke test of a RUNNING stack, through nginx like a browser would.
# Signs in as the bootstrap manager through Mailpit, builds a tiny catalog, sends a
# report as an employee, generates a deck and checks the summary.
#
#   scripts/smoke.sh [base_url] [mailpit_url]
#
set -euo pipefail

BASE=${1:-http://127.0.0.1:8080}
MAIL=${2:-http://127.0.0.1:8025}
API="$BASE/api"
MANAGER=${SMOKE_MANAGER:-smoke.manager@xynotransit.example}
EMPLOYEE=${SMOKE_EMPLOYEE:-smoke.employee@xynotransit.example}

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
M=$(login "$MANAGER")
[ "$(curl -fsS "$API/me" -H "authorization: Bearer $M" | j "d['role']")" = controller ] || fail "manager role"

step "no one else can read anything without a token"
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/catalog")
[ "$code" = 401 ] || fail "catalog without token returned $code"

H=(-H "authorization: Bearer $M" -H 'content-type: application/json')
step "manager builds a team, a person, a seat with 2 counts and 2 targets"
TEAM=$(curl -fsS -X POST "$API/teams" "${H[@]}" -d '{"name":"Smoke team"}' | j "d['id']")
PERSON=$(curl -fsS -X POST "$API/persons" "${H[@]}" -d "{\"full_name\":\"Smoke Employee\",\"email\":\"$EMPLOYEE\",\"app_role\":\"contributor\"}" | j "d['id']")
SEAT=$(curl -fsS -X POST "$API/assignments" "${H[@]}" -d "{\"person_id\":\"$PERSON\",\"team_id\":\"$TEAM\",\"role_title\":\"Tester\"}" | j "d['id']")
DEF=$(curl -fsS -X PUT "$API/assignments/$SEAT/definitions" "${H[@]}" \
  -d '{"metrics":[{"label":"Sea"},{"label":"Air"}],"kpis":[{"text":"All files on time"},{"text":"No errors"}]}')
echo "$DEF" | j "len(d['metrics'])" | grep -qx 2 || fail "definitions"

step "employee signs in and sends the report"
E=$(login "$EMPLOYEE")
EH=(-H "authorization: Bearer $E" -H 'content-type: application/json')
PERIOD=$(curl -fsS -X POST "$API/periods/ensure" "${EH[@]}" -d '{"start_month":"2026-02-01"}' | j "d['id']")
BODY=$(echo "$DEF" | python3 -c "
import sys,json
a=json.load(sys.stdin)
vals=[{'metric_def_id':m['id'],'month_offset':o,'value':10+o} for m in a['metrics'] for o in range(3)]
kpis=[{'kpi_def_id':k['id'],'status':'met','comment':'Smoke comment'} for k in a['kpis']]
print(json.dumps({'values':vals,'kpis':kpis,'notes':[{'kind':'well','position':1,'text':'Smoke test note'}]}))")
curl -fsS -X PUT "$API/periods/$PERIOD/reports/$SEAT" "${EH[@]}" -d "$BODY" | j "d['status']" | grep -qx submitted || fail "send report"
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/periods/$PERIOD/deck" -H "authorization: Bearer $E")
[ "$code" = 403 ] || fail "employee must not read the deck (got $code)"

step "manager sets the slide words, generates the deck, reads the summary"
curl -fsS -X GET "$API/periods/$PERIOD/deck-text" -H "authorization: Bearer $M" >/dev/null 2>&1 \
  && curl -fsS -X PUT "$API/periods/$PERIOD/deck-text" "${H[@]}" \
       -d '{"settings":{"title":"Smoke Test Review"}}' -o /dev/null || echo "(deck-text endpoint not present, skipped)"
curl -fsS -X POST "$API/periods/$PERIOD/deck" "${H[@]}" -d '{}' | j "d['included_count']" | grep -qx 1 || fail "generate deck"
curl -fsS "$API/summary?period_id=$PERIOD" -H "authorization: Bearer $M" | j "d['submitted']" | grep -qx 1 || fail "summary"

echo "SMOKE OK"
