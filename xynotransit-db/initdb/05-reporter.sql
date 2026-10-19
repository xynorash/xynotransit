-- Xynotransit reporter words: the name, country and role a person types on their own report.
-- Runs after 04-deck-text.sql. Safe to run again.
--
-- report.reporter_*: what the reporter typed. NULL on reports sent before this file; those
--   still read from the catalog profile (person name, role title, team name).
-- login_attempt: one row per magic link request, keyed by the normalised email STRING, so the
--   sign-in rate limit is the same for addresses that exist and addresses that do not.

begin;

alter table report add column if not exists reporter_name    text;
alter table report add column if not exists reporter_country text;
alter table report add column if not exists reporter_role    text;

create table if not exists login_attempt (
  email text        not null,
  at    timestamptz not null default now()
);
create index if not exists login_attempt_email_idx on login_attempt (email, at);

commit;
