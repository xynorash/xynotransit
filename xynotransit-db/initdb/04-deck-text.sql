-- Xynotransit deck texts: the words of the slides (title, date line, headings) a manager can change.
-- Runs after 03-dynamic.sql. Safe to run again.
--
-- deck_text: the words a period has of its own. A period without a row inherits the latest earlier
--   period's words, else the built-in defaults (resolved by the API, not here).
-- deck_run.texts: the effective words frozen into each generated deck, like the data snapshots.
--   '{}' (decks made before this file) reads as the defaults.

begin;

create table if not exists deck_text (
  period_id  uuid primary key references period(id) on delete cascade,
  settings   jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references person(id)
);

alter table deck_run add column if not exists texts jsonb not null default '{}'::jsonb;

commit;
