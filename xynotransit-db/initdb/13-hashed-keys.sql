-- Xynotransit: sign-in limits that keep no readable names or addresses, trusted addresses, and the
-- audit kind for a password chosen after signing in by a link.
--
-- login_failure used to keep what was typed in the username box (people sometimes type their
-- password there) and the client address. Now both columns hold a keyed hash only: HMAC-SHA256 as
-- 64 lowercase hex characters, made by the API with a key derived from JWT_SECRET (HKDF-SHA256,
-- label xt-ratelimit-v1). The old rows were only 15 minute counters, so they are dropped, not
-- converted. Column ip becomes address_key.
-- login_success remembers which addresses signed in successfully for a username (by password or by
-- link): one row per (username_key, address_key), refreshed on each success, kept 30 days. Such an
-- address is "trusted" when a name is under heavy attack from many addresses.
-- password_audit.kind gains 'change-via-link'.
-- Safe to run again: a table that already has address_key is left alone. Applied files are never
-- edited; this one only adds.

begin;

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'login_failure' and column_name = 'ip') then
    drop table login_failure;
  end if;
end $$;

create table if not exists login_failure (
  id           bigint generated always as identity primary key,
  username_key text        not null,
  address_key  text        not null,
  at           timestamptz not null default now(),
  constraint login_failure_keys_ck
    check (username_key ~ '^[0-9a-f]{64}$' and address_key ~ '^[0-9a-f]{64}$')
);
create index if not exists login_failure_user_idx on login_failure (username_key, at);
create index if not exists login_failure_pair_idx on login_failure (username_key, address_key, at);
create index if not exists login_failure_addr_idx on login_failure (address_key, at);
create index if not exists login_failure_at_idx   on login_failure (at);

create table if not exists login_success (
  id           bigint generated always as identity primary key,
  username_key text        not null,
  address_key  text        not null,
  at           timestamptz not null default now(),
  constraint login_success_keys_ck
    check (username_key ~ '^[0-9a-f]{64}$' and address_key ~ '^[0-9a-f]{64}$')
);
create unique index if not exists login_success_pair_key on login_success (username_key, address_key);
create index if not exists login_success_at_idx on login_success (at);

do $$
begin
  alter table password_audit drop constraint if exists password_audit_kind_ck;
  alter table password_audit add constraint password_audit_kind_ck
    check (kind in ('change', 'change-via-link', 'reset', 'remove', 'cli'));
end $$;

-- Housekeeping: the old body, sign-in failures older than a day and trusted addresses older than 30 days.
create or replace function xt_purge_expired() returns integer language plpgsql as $$
declare n integer := 0; k integer;
begin
  delete from login_token where expires_at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_attempt where at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_failure where at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_success where at < now() - interval '30 days';
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

insert into schema_migration (file) values ('13-hashed-keys.sql') on conflict do nothing;

commit;
