-- Xynotransit Regional Logistics Meeting: database schema
-- PostgreSQL 15 or later.
--
-- Shape of the data:
--   team 1--n assignment n--1 person        (a person can hold several assignments)
--   assignment 1--n metric_def, kpi_def     (what that assignment reports on)
--   period 1--n report n--1 assignment      (one report per assignment per 3-month period)
--   report 1--n report_metric_value / report_kpi_result / report_note
--   period 1--n deck_run 1--n deck_run_item (frozen snapshot of the generated slides)

begin;

create extension if not exists pgcrypto;

-- ---------- types ----------
create type kpi_status    as enum ('met', 'partly', 'missed');
create type note_kind     as enum ('well', 'wrong', 'next');          -- highlights, lowlights, next 3 months
create type report_status as enum ('draft', 'submitted');
create type period_status as enum ('open', 'closed');
create type app_role      as enum ('contributor', 'controller');       -- controller generates the slides

-- ---------- reference data ----------
create table team (
  id    smallint generated always as identity primary key,
  code  text     not null unique,
  name  text     not null unique,
  sort  smallint not null
);

create table person (
  id        uuid primary key default gen_random_uuid(),
  full_name text not null,
  email     text unique,
  app_role  app_role not null default 'contributor',
  active    boolean  not null default true
);

-- A seat in the organisation: who, in which team, doing what.
-- Tahina is one person with two assignments (export declarant in Tana, BSC creation in Antsirabe).
create table assignment (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,                       -- stable slug, e.g. 'rova', 'tahina-bsc'
  person_id  uuid not null references person(id),
  team_id    smallint not null references team(id),
  role_title text not null,                              -- 'Import', 'Declarant export (Abe)', ...
  sort       smallint not null,                          -- running order in the deck
  active     boolean not null default true,
  unique (person_id, team_id, role_title)
);
create index assignment_team_idx on assignment (team_id, sort);

-- What an assignment counts each month (up to three series, drawn as blue, orange, green bars).
create table metric_def (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignment(id) on delete cascade,
  key           text not null,
  label         text not null,
  series        smallint not null check (series between 0 and 2),
  retired_at    timestamptz,
  unique (assignment_id, key),
  unique (id, assignment_id)
);
create unique index metric_def_series_uq on metric_def (assignment_id, series) where retired_at is null;

-- The targets an assignment is judged on. Edit a target by retiring it and adding a new row,
-- so old reports keep the wording they were answered against.
create table kpi_def (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignment(id) on delete cascade,
  sort          smallint not null,
  text          text not null,
  retired_at    timestamptz,
  unique (id, assignment_id)
);
create index kpi_def_assignment_idx on kpi_def (assignment_id, sort);

-- Suggestion chips shown under each notes box.
create table note_suggestion (
  id     smallint generated always as identity primary key,
  kind   note_kind not null,
  text   text not null check (char_length(text) between 1 and 70),
  sort   smallint not null default 0,
  active boolean  not null default true,
  unique (kind, text)
);

-- ---------- reporting ----------
-- One reporting period = three consecutive months, identified by its first month.
create table period (
  id           uuid primary key default gen_random_uuid(),
  start_month  date not null unique
               check (start_month = date_trunc('month', start_month)::date),
  meeting_date date,
  status       period_status not null default 'open',
  created_at   timestamptz   not null default now()
);

create table report (
  id            uuid primary key default gen_random_uuid(),
  period_id     uuid not null references period(id),
  assignment_id uuid not null references assignment(id),
  status        report_status not null default 'draft',
  submitted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (period_id, assignment_id),                      -- sending again replaces, never duplicates
  unique (id, assignment_id),
  check (status = 'draft' or submitted_at is not null)
);
create index report_period_idx on report (period_id, status);

-- Monthly counts. month_offset 0, 1, 2 = first, second, third month of the period.
-- The composite foreign keys keep a report from using another assignment's metric.
create table report_metric_value (
  report_id     uuid     not null,
  assignment_id uuid     not null,
  metric_def_id uuid     not null,
  month_offset  smallint not null check (month_offset between 0 and 2),
  value         integer  not null check (value >= 0),
  primary key (report_id, metric_def_id, month_offset),
  foreign key (report_id, assignment_id)     references report(id, assignment_id) on delete cascade,
  foreign key (metric_def_id, assignment_id) references metric_def(id, assignment_id)
);

create table report_kpi_result (
  report_id     uuid not null,
  assignment_id uuid not null,
  kpi_def_id    uuid not null,
  status        kpi_status not null,
  comment       text check (comment is null or char_length(comment) <= 200),
  primary key (report_id, kpi_def_id),
  foreign key (report_id, assignment_id) references report(id, assignment_id) on delete cascade,
  foreign key (kpi_def_id, assignment_id) references kpi_def(id, assignment_id)
);

-- At most three short points per box, each 70 characters or fewer (so slides never overflow).
create table report_note (
  id        bigint generated always as identity primary key,
  report_id uuid not null references report(id) on delete cascade,
  kind      note_kind not null,
  position  smallint  not null check (position between 1 and 3),
  text      text      not null check (char_length(text) between 1 and 70),
  unique (report_id, kind, position)
);

-- ---------- generated slides ----------
-- The controller generates the deck by hand. The snapshot freezes what each slide was built from.
create table deck_run (
  id             uuid primary key default gen_random_uuid(),
  period_id      uuid not null references period(id),
  generated_by   uuid references person(id),
  generated_at   timestamptz not null default now(),
  expected_count integer not null,
  included_count integer not null
);

create table deck_run_item (
  deck_run_id uuid not null references deck_run(id) on delete cascade,
  report_id   uuid not null references report(id),
  sort        integer not null,
  snapshot    jsonb   not null,
  primary key (deck_run_id, report_id)
);

-- ---------- behaviour ----------
create function touch_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger report_touch before update on report
  for each row execute function touch_updated_at();

-- A report can only be submitted when every metric has three values and every KPI is answered.
create function submit_report(p_report uuid) returns void language plpgsql as $$
declare
  v_assignment uuid;
  v_missing_values integer;
  v_missing_kpis integer;
begin
  select assignment_id into v_assignment from report where id = p_report for update;
  if v_assignment is null then
    raise exception 'report % not found', p_report;
  end if;

  select count(*) into v_missing_values
  from metric_def m
  cross join generate_series(0, 2) as g(offs)
  where m.assignment_id = v_assignment and m.retired_at is null
    and not exists (select 1 from report_metric_value v
                    where v.report_id = p_report and v.metric_def_id = m.id and v.month_offset = g.offs);

  select count(*) into v_missing_kpis
  from kpi_def k
  where k.assignment_id = v_assignment and k.retired_at is null
    and not exists (select 1 from report_kpi_result r where r.report_id = p_report and r.kpi_def_id = k.id);

  if v_missing_values > 0 then
    raise exception 'report % is missing % monthly value(s)', p_report, v_missing_values;
  end if;
  if v_missing_kpis > 0 then
    raise exception 'report % has % unanswered KPI(s)', p_report, v_missing_kpis;
  end if;

  update report set status = 'submitted', submitted_at = now() where id = p_report;
end $$;

-- ---------- views the app and the deck builder read ----------
create view v_period_label as
select p.id as period_id,
       p.start_month,
       (p.start_month + interval '2 months')::date as last_month,
       to_char(p.start_month, 'Mon') || ' to ' || to_char(p.start_month + interval '2 months', 'Mon YYYY') as label
from period p;

-- How many reports are in, per period.
create view v_period_progress as
select p.id as period_id,
       (select count(*) from assignment a where a.active)                       as expected,
       count(r.id) filter (where r.status = 'submitted')                        as submitted
from period p
left join report r on r.period_id = p.id
group by p.id;

-- Who is still missing.
create view v_missing_reports as
select p.id as period_id, a.id as assignment_id, a.code, pe.full_name, a.role_title, t.name as team
from period p
cross join assignment a
join person pe on pe.id = a.person_id
join team t on t.id = a.team_id
where a.active
  and not exists (select 1 from report r
                  where r.period_id = p.id and r.assignment_id = a.id and r.status = 'submitted');

-- Monthly counts with real month dates, ready for the bar chart.
create view v_monthly_volume as
select r.period_id, r.id as report_id, a.code, m.label, m.series,
       v.month_offset,
       (p.start_month + (v.month_offset || ' months')::interval)::date as month,
       v.value
from report_metric_value v
join report r on r.id = v.report_id
join period p on p.id = r.period_id
join assignment a on a.id = r.assignment_id
join metric_def m on m.id = v.metric_def_id;

create view v_metric_total as
select report_id, metric_def_id, sum(value)::integer as total
from report_metric_value
group by report_id, metric_def_id;

-- "KPI 3 of 3 met" badge.
create view v_kpi_score as
select r.id as report_id,
       count(*) filter (where k.status = 'met')    as met,
       count(*) filter (where k.status = 'partly') as partly,
       count(*) filter (where k.status = 'missed') as missed,
       count(*)                                    as total
from report r
join report_kpi_result k on k.report_id = r.id
group by r.id;

commit;
