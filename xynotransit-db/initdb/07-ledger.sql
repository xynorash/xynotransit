-- Xynotransit migration ledger: which initdb files this database has had.
-- Runs after 06-integrity.sql. Safe to run again.
--
-- initdb/*.sql only runs on the first start of an empty volume, so a database that lives on
-- needs the new files applied by hand. `scripts/migrate.sh` does that: it reads this table and
-- applies the files that are missing, in name order. Every file from 03 on can run twice.
-- 01 and 02 cannot (they create types and tables), which is why the ledger exists.

begin;

create table if not exists schema_migration (
  file       text primary key,
  applied_at timestamptz not null default now()
);

insert into schema_migration (file) values
  ('01-schema.sql'), ('02-api.sql'), ('03-dynamic.sql'), ('04-deck-text.sql'),
  ('05-reporter.sql'), ('06-integrity.sql'), ('07-ledger.sql')
on conflict do nothing;

-- Housekeeping the API and the maintenance script call: drop spent sign-in rows.
create or replace function xt_purge_expired() returns integer language plpgsql as $$
declare n integer := 0; k integer;
begin
  delete from login_token where expires_at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_attempt where at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

commit;
