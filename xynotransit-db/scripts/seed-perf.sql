-- Performance seed: a big organisation, for timing the API and reading EXPLAIN plans.
-- 12 teams, 300 active seats (one person each), 8 counts and 4 targets per seat, 24 periods
-- (2021-01 to 2026-10, quarterly), every seat reported in every period: 7200 reports and
-- 172800 monthly values. Person 1 is the manager.
--
-- Only for a SCRATCH database that already has the schema (never the live one):
--   createdb scratch; for f in initdb/*.sql; do psql -d scratch -f $f; done; psql -d scratch -f scripts/seed-perf.sql
-- tests/perf.rs uses the same file.

insert into team (code, name, sort) select 't' || g, 'Team ' || g, g from generate_series(1, 12) g;
insert into person (id, full_name, email, app_role)
  select ('00000000-0000-0000-0001-' || lpad(g::text, 12, '0'))::uuid, 'Person ' || g, 'p' || g || '@x.org',
         case when g = 1 then 'controller'::app_role else 'contributor'::app_role end
  from generate_series(1, 300) g;
insert into assignment (id, code, person_id, team_id, role_title, sort, active)
  select ('00000000-0000-0000-0002-' || lpad(g::text, 12, '0'))::uuid, 'seat-' || g,
         ('00000000-0000-0000-0001-' || lpad(g::text, 12, '0'))::uuid, 1 + g % 12, 'Role ' || g, g, true
  from generate_series(1, 300) g;
insert into metric_def (id, assignment_id, key, label, series)
  select ('00000000-0000-0000-0003-' || lpad((a * 100 + m)::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0002-' || lpad(a::text, 12, '0'))::uuid, 'k' || m, 'Count ' || m, m
  from generate_series(1, 300) a, generate_series(0, 8 - 1) m;
insert into kpi_def (id, assignment_id, sort, text)
  select ('00000000-0000-0000-0004-' || lpad((a * 100 + k)::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0002-' || lpad(a::text, 12, '0'))::uuid, k, 'Target ' || k
  from generate_series(1, 300) a, generate_series(1, 4) k;
insert into period (id, start_month)
  select ('00000000-0000-0000-0005-' || lpad(p::text, 12, '0'))::uuid,
         (date '2021-01-01' + ((p - 1) * 3 || ' months')::interval)::date
  from generate_series(1, 24) p;
insert into report (id, period_id, assignment_id, status, submitted_at, reporter_name, reporter_country, reporter_role)
  select ('00000000-0000-0000-0006-' || lpad((p * 1000 + a)::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0005-' || lpad(p::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0002-' || lpad(a::text, 12, '0'))::uuid, 'submitted', now(),
         'Person ' || a, 'Country ' || (a % 12), 'Role ' || a
  from generate_series(1, 24) p, generate_series(1, 300) a;
insert into report_metric_value (report_id, assignment_id, metric_def_id, month_offset, value)
  select ('00000000-0000-0000-0006-' || lpad((p * 1000 + a)::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0002-' || lpad(a::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0003-' || lpad((a * 100 + m)::text, 12, '0'))::uuid, o, (p * a + m * 7 + o) % 5000
  from generate_series(1, 24) p, generate_series(1, 300) a,
       generate_series(0, 8 - 1) m, generate_series(0, 2) o;
insert into report_kpi_result (report_id, assignment_id, kpi_def_id, status, comment)
  select ('00000000-0000-0000-0006-' || lpad((p * 1000 + a)::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0002-' || lpad(a::text, 12, '0'))::uuid,
         ('00000000-0000-0000-0004-' || lpad((a * 100 + k)::text, 12, '0'))::uuid,
         (array['met','partly','missed'])[1 + (p + a + k) % 3]::kpi_status, null
  from generate_series(1, 24) p, generate_series(1, 300) a, generate_series(1, 4) k;
insert into report_note (report_id, kind, position, text)
  select ('00000000-0000-0000-0006-' || lpad((p * 1000 + a)::text, 12, '0'))::uuid, kind, pos, 'A short note'
  from generate_series(1, 24) p, generate_series(1, 300) a,
       unnest(array['well'::note_kind, 'wrong', 'next']) kind, generate_series(1, 2) pos;
analyze;
