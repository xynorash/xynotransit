-- Xynotransit integrity: the database refuses bad data even if the API has a bug.
-- Runs after 05-reporter.sql. Safe to run again (every step checks first).
--
-- What this adds
--   * CHECK constraints for lengths, blank text, ranges and shapes. They mirror the API rules in
--     xynotransit-api/src/rules.rs (see tests/fixtures/rules.json). On a database that already holds
--     data, each check is added NOT VALID (enforced for every new or changed row) and then validated;
--     when old rows break it, validation is skipped with a WARNING and the rows are left alone.
--   * Case-insensitive unique indexes: person email, team name, live count name per seat.
--   * Frozen decks: deck_run and deck_run_item rows can never be updated. They can only be deleted
--     with a deliberate switch (see "Deck history" below).
--   * updated_at on the catalog tables, kept by trigger (only when something really changed).
--   * Indexes for the queries the API runs.

begin;

-- ---------- helpers (live only for this session) ----------
create or replace function pg_temp.xt_add_check(p_table regclass, p_name text, p_expr text) returns void
language plpgsql as $$
begin
  if exists (select 1 from pg_constraint where conrelid = p_table and conname = p_name) then
    return;
  end if;
  execute format('alter table %s add constraint %I check (%s) not valid', p_table, p_name, p_expr);
  begin
    execute format('alter table %s validate constraint %I', p_table, p_name);
  exception when check_violation then
    raise warning 'constraint % on % left NOT VALID: some old rows break it (new rows are still checked)',
      p_name, p_table;
  end;
end $$;

create or replace function pg_temp.xt_add_unique(p_name text, p_table regclass, p_cols text, p_where text) returns void
language plpgsql as $$
begin
  if exists (select 1 from pg_class where relname = p_name and relnamespace = 'public'::regnamespace) then
    return;
  end if;
  begin
    execute format('create unique index %I on %s (%s) %s', p_name, p_table, p_cols,
                   coalesce('where ' || p_where, ''));
  exception when unique_violation then
    raise warning 'unique index % on % skipped: old rows already repeat a value', p_name, p_table;
  end;
end $$;

-- ---------- people ----------
select pg_temp.xt_add_check('person', 'person_full_name_ck',
  $c$char_length(full_name) between 1 and 80 and full_name = btrim(full_name)$c$);
select pg_temp.xt_add_check('person', 'person_email_ck',
  $c$email is null or (char_length(email) between 3 and 254 and email = btrim(email)
     and email !~ '[[:space:]]' and position('@' in email) > 1)$c$);
-- Case is not forced (lookups all use lower(email)); the unique index below stops case twins.
select pg_temp.xt_add_unique('person_email_lower_uq', 'person', 'lower(email)', 'email is not null');

-- ---------- teams ----------
select pg_temp.xt_add_check('team', 'team_name_ck',
  $c$char_length(name) between 1 and 60 and name = btrim(name)$c$);
select pg_temp.xt_add_check('team', 'team_code_ck', $c$char_length(code) between 1 and 64$c$);
select pg_temp.xt_add_check('team', 'team_sort_ck', $c$sort >= 0$c$);
select pg_temp.xt_add_unique('team_name_lower_uq', 'team', 'lower(name)', null);

-- ---------- seats ----------
select pg_temp.xt_add_check('assignment', 'assignment_role_title_ck',
  $c$char_length(role_title) between 1 and 80 and role_title = btrim(role_title)$c$);
select pg_temp.xt_add_check('assignment', 'assignment_code_ck', $c$char_length(code) between 1 and 64$c$);
select pg_temp.xt_add_check('assignment', 'assignment_sort_ck', $c$sort >= 0$c$);

-- ---------- counts and targets ----------
select pg_temp.xt_add_check('metric_def', 'metric_def_label_ck',
  $c$char_length(label) between 1 and 60 and label = btrim(label)$c$);
select pg_temp.xt_add_check('metric_def', 'metric_def_key_ck', $c$char_length(key) between 1 and 64$c$);
select pg_temp.xt_add_unique('metric_def_label_live_uq', 'metric_def', 'assignment_id, lower(label)',
  'retired_at is null');
select pg_temp.xt_add_check('kpi_def', 'kpi_def_text_ck',
  $c$char_length(text) between 1 and 200 and text = btrim(text)$c$);
select pg_temp.xt_add_check('kpi_def', 'kpi_def_sort_ck', $c$sort >= 0$c$);

-- ---------- periods ----------
select pg_temp.xt_add_check('period', 'period_start_range_ck',
  $c$start_month between date '2000-01-01' and date '2100-12-31'$c$);
select pg_temp.xt_add_check('period', 'period_meeting_range_ck',
  $c$meeting_date is null or meeting_date between date '2000-01-01' and date '2100-12-31'$c$);

-- ---------- reports ----------
-- The three reporter words are all there or all missing (old reports), and never blank.
select pg_temp.xt_add_check('report', 'report_reporter_ck',
  $c$(reporter_name is null and reporter_country is null and reporter_role is null)
     or (reporter_name is not null and reporter_country is not null and reporter_role is not null
         and char_length(reporter_name) between 1 and 80 and reporter_name = btrim(reporter_name)
         and char_length(reporter_country) between 1 and 80 and reporter_country = btrim(reporter_country)
         and char_length(reporter_role) between 1 and 80 and reporter_role = btrim(reporter_role))$c$);
select pg_temp.xt_add_check('report_metric_value', 'report_metric_value_range_ck',
  $c$value between 0 and 1000000000$c$);
select pg_temp.xt_add_check('report_kpi_result', 'report_kpi_result_comment_ck',
  $c$comment is null or (btrim(comment) <> '' and comment = btrim(comment))$c$);
select pg_temp.xt_add_check('report_note', 'report_note_text_ck',
  $c$btrim(text) <> '' and text = btrim(text)$c$);

-- ---------- decks and sign-in ----------
select pg_temp.xt_add_check('deck_run', 'deck_run_counts_ck',
  $c$expected_count >= 0 and included_count >= 0$c$);
select pg_temp.xt_add_check('deck_run', 'deck_run_texts_ck', $c$jsonb_typeof(texts) = 'object'$c$);
select pg_temp.xt_add_check('deck_run_item', 'deck_run_item_sort_ck', $c$sort >= 1$c$);
select pg_temp.xt_add_check('deck_run_item', 'deck_run_item_snapshot_ck',
  $c$jsonb_typeof(snapshot) = 'object'$c$);
select pg_temp.xt_add_check('deck_text', 'deck_text_settings_ck', $c$jsonb_typeof(settings) = 'object'$c$);
select pg_temp.xt_add_check('login_attempt', 'login_attempt_email_ck',
  $c$char_length(email) between 1 and 254$c$);

-- ---------- deck history is frozen ----------
-- Decision: a generated deck is a record of what was shown at a meeting. It is never edited.
--   deck_run, deck_run_item   UPDATE: always refused.
--   deck_run                  DELETE / TRUNCATE: refused unless the session says
--                             `set local xt.allow_deck_delete = 'on'` (a deliberate maintenance act).
--   deck_run_item             DELETE: allowed when its deck_run is already gone (ON DELETE CASCADE),
--                             otherwise needs the same switch.
-- Deleting a period or a report that a deck refers to is already refused by foreign keys.
create or replace function xt_deck_frozen() returns trigger language plpgsql as $$
declare
  v_ok boolean := coalesce(current_setting('xt.allow_deck_delete', true), '') = 'on';
begin
  if tg_op = 'UPDATE' then
    raise exception 'a generated deck cannot be changed (% %)', tg_table_name, tg_op
      using errcode = 'restrict_violation';
  end if;
  if v_ok then
    return case when tg_op = 'DELETE' then old else null end;
  end if;
  if tg_op = 'DELETE' and tg_table_name = 'deck_run_item' then
    if not exists (select 1 from deck_run where id = old.deck_run_id) then
      return old;  -- cascade from a deck that is being removed on purpose
    end if;
  end if;
  raise exception 'a generated deck cannot be removed (% %)', tg_table_name, tg_op
    using errcode = 'restrict_violation';
end $$;

drop trigger if exists deck_run_frozen on deck_run;
create trigger deck_run_frozen before update or delete on deck_run
  for each row execute function xt_deck_frozen();
drop trigger if exists deck_run_frozen_truncate on deck_run;
create trigger deck_run_frozen_truncate before truncate on deck_run
  for each statement execute function xt_deck_frozen();
drop trigger if exists deck_run_item_frozen on deck_run_item;
create trigger deck_run_item_frozen before update or delete on deck_run_item
  for each row execute function xt_deck_frozen();
drop trigger if exists deck_run_item_frozen_truncate on deck_run_item;
create trigger deck_run_item_frozen_truncate before truncate on deck_run_item
  for each statement execute function xt_deck_frozen();

-- ---------- updated_at ----------
alter table person     add column if not exists updated_at timestamptz not null default now();
alter table team       add column if not exists updated_at timestamptz not null default now();
alter table assignment add column if not exists updated_at timestamptz not null default now();
alter table metric_def add column if not exists updated_at timestamptz not null default now();
alter table kpi_def    add column if not exists updated_at timestamptz not null default now();
alter table period     add column if not exists updated_at timestamptz not null default now();

-- Moves updated_at only when a real column changed, so an UPDATE that sets the same values is quiet.
create or replace function xt_touch() returns trigger language plpgsql as $$
begin
  if new.updated_at is distinct from old.updated_at then
    return new;  -- set on purpose (restore, repair): leave it
  end if;
  if (to_jsonb(new) - 'updated_at') is distinct from (to_jsonb(old) - 'updated_at') then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['person', 'team', 'assignment', 'metric_def', 'kpi_def', 'period'] loop
    execute format('drop trigger if exists %I on %I', t || '_touch', t);
    execute format('create trigger %I before update on %I for each row execute function xt_touch()',
                   t || '_touch', t);
  end loop;
end $$;

-- ---------- views agree with the API ----------
-- A seat is expected in a period when the seat and its person are both switched on (the API
-- counts the same way). Same columns as in 01-schema.sql, so create or replace is allowed.
create or replace view v_period_progress as
select p.id as period_id,
       (select count(*) from assignment a join person pe on pe.id = a.person_id
         where a.active and pe.active)                                        as expected,
       count(r.id) filter (where r.status = 'submitted')                      as submitted
from period p
left join report r on r.period_id = p.id
group by p.id;

create or replace view v_missing_reports as
select p.id as period_id, a.id as assignment_id, a.code, pe.full_name, a.role_title, t.name as team
from period p
cross join assignment a
join person pe on pe.id = a.person_id
join team t on t.id = a.team_id
where a.active and pe.active
  and not exists (select 1 from report r
                  where r.period_id = p.id and r.assignment_id = a.id and r.status = 'submitted');

-- ---------- indexes for the queries the API runs ----------
-- (the unique constraints of 01-schema.sql already cover period+assignment, assignment+key and so on)
create index if not exists report_assignment_idx    on report (assignment_id);
create index if not exists assignment_person_idx    on assignment (person_id);
create index if not exists assignment_active_idx    on assignment (team_id, sort, code) where active;
create index if not exists deck_run_latest_idx      on deck_run (period_id, generated_at desc, id desc);
create index if not exists deck_run_item_report_idx on deck_run_item (report_id);
create index if not exists deck_run_item_sort_idx   on deck_run_item (deck_run_id, sort);
create index if not exists report_metric_value_metric_idx on report_metric_value (metric_def_id);
create index if not exists report_kpi_result_kpi_idx on report_kpi_result (kpi_def_id);
create index if not exists login_token_expiry_idx   on login_token (expires_at);
create index if not exists period_start_idx         on period (start_month desc);

drop function pg_temp.xt_add_check(regclass, text, text);
drop function pg_temp.xt_add_unique(text, regclass, text, text);

commit;
