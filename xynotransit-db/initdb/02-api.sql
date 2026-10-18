-- Xynotransit API additions: magic link sign-in and change notifications.
-- Runs after 01-schema.sql. New objects only; the core schema is untouched.

begin;

-- One row per magic link. Only the SHA-256 of the token is stored.
-- The same rows drive the rate limit (links created per person in the last hour).
create table login_token (
  token_hash bytea       primary key,
  person_id  uuid        not null references person(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
create index login_token_person_idx on login_token (person_id, created_at);

-- Tell the API that something changed for a period. The API listens on xt_changes
-- and pushes the message to open browsers (Server-Sent Events).
-- Payload: {"kind":"reports"|"deck","period_id":"<uuid>"}
create function xt_notify_change() returns trigger language plpgsql as $$
declare
  v_period uuid;
  v_kind   text;
  v_report uuid;
begin
  if tg_table_name = 'deck_run' then
    v_kind := 'deck';
    v_period := coalesce(new.period_id, old.period_id);
  elsif tg_table_name = 'report' then
    v_kind := 'reports';
    v_period := coalesce(new.period_id, old.period_id);
  else
    v_kind := 'reports';
    v_report := coalesce(new.report_id, old.report_id);
    select period_id into v_period from report where id = v_report;
  end if;

  if v_period is not null then
    perform pg_notify('xt_changes',
      json_build_object('kind', v_kind, 'period_id', v_period)::text);
  end if;
  return null;
end $$;

create trigger report_notify
  after insert or update or delete on report
  for each row execute function xt_notify_change();
create trigger report_metric_value_notify
  after insert or update or delete on report_metric_value
  for each row execute function xt_notify_change();
create trigger report_kpi_result_notify
  after insert or update or delete on report_kpi_result
  for each row execute function xt_notify_change();
create trigger report_note_notify
  after insert or update or delete on report_note
  for each row execute function xt_notify_change();
create trigger deck_run_notify
  after insert or update or delete on deck_run
  for each row execute function xt_notify_change();

commit;
