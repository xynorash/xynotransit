-- Xynotransit dynamic catalog: managers define teams, people, seats and counts in the app.
-- Runs after 02-api.sql. Safe to run again.
--
-- A seat can now have up to 8 counts (series 0..7). The constraint allows a wider range
-- (0..9999) so the API can park rows in a temporary range while it reorders them, because
-- the partial unique index on (assignment_id, series) is checked row by row.

begin;

alter table metric_def drop constraint if exists metric_def_series_check;
alter table metric_def add constraint metric_def_series_check check (series between 0 and 9999);

commit;
