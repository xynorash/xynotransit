-- Xynotransit: decks keep the reports of switched-off seats and people.
-- A deck now includes every submitted report of the period. `included_count` counts them all;
-- `switched_off_count` says how many of those came from a seat or person that was switched off
-- when the deck was made, so the header can read "1 of 1 reports in, plus 1 from a switched-off
-- person". Old decks have 0 (they never included such reports). Safe to run again.

begin;

alter table deck_run add column if not exists switched_off_count integer not null default 0;

do $$
begin
  alter table deck_run add constraint deck_run_switched_off_ck
    check (switched_off_count >= 0 and switched_off_count <= included_count);
exception when duplicate_object then null;
end $$;

insert into schema_migration (file) values ('11-deck-switched-off.sql') on conflict do nothing;

commit;
