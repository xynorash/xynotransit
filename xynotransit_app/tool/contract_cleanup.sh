#!/usr/bin/env bash
# Removes what an interrupted contract run left in the dev database: people,
# seats, teams and periods created under a "ct<hex>" tag by test/contract.
# A finished run cleans up after itself; use this only after a killed one.
#   tool/contract_cleanup.sh
set -euo pipefail
docker exec -i xynotransit-db-db-1 psql -U xynotransit -d xynotransit -v ON_ERROR_STOP=1 -1 <<'SQL'
set local xt.allow_deck_delete = 'on';
create temp table ct_person as select id from person where email like 'ct%@contract.example';
create temp table ct_seat as select id from assignment where person_id in (select id from ct_person);
create temp table ct_period as
  select id from period where start_month >= '2080-01-01'
  or (start_month in ('2000-01-01', '2100-12-01') and not exists (select 1 from report r where r.period_id = period.id));
delete from deck_run_item where deck_run_id in (select id from deck_run where period_id in (select id from ct_period));
delete from deck_run where period_id in (select id from ct_period);
delete from report where period_id in (select id from ct_period) or assignment_id in (select id from ct_seat);
delete from period where id in (select id from ct_period);
delete from assignment where id in (select id from ct_seat);
delete from person where id in (select id from ct_person);
delete from team where name like 'CT%' and not exists (select 1 from assignment a where a.team_id = team.id);
delete from login_attempt where email like 'ct%@contract.example';
SQL
echo "contract leftovers removed"
