-- Xynotransit: usernames and passwords next to the sign-in links.
-- Adds to person: username (unique ignoring case, stored lowercase), password_hash (an Argon2id PHC
-- string, never the password), must_change_password, session_epoch (a password change, reset or
-- removal adds 1 and so ends every older session) and password_changed_at.
-- Adds login_failure (the rows behind the sign-in rate limits: who was tried and from where; never
-- a password) and password_audit (who set, reset or removed a password and when; never a password
-- or a hash).
-- Existing people get a username made from the part of their email before the @, numbered on
-- conflict (rosa.rakoto, rosa.rakoto2). New people get one from a trigger when the insert has none,
-- so older code, seed scripts and the bootstrap manager keep working.
-- Safe to run again: nothing is rewritten, people who have a username keep it. Applied files are
-- never edited; this one only adds.

begin;

alter table person add column if not exists username            text;
alter table person add column if not exists password_hash       text;
alter table person add column if not exists must_change_password boolean not null default false;
alter table person add column if not exists session_epoch       integer not null default 0;
alter table person add column if not exists password_changed_at timestamptz;

-- The username a person would get from an email: the part before the @, lowercase, Latin-1 accents
-- folded to plain letters, only a-z 0-9 . _ - kept, no dots at the ends, at most 40 characters,
-- at least 3 (shorter ones become user.<it>; nothing left becomes user).
create or replace function xt_username_base(email text) returns text language plpgsql immutable as $$
declare s text;
begin
  s := lower(split_part(coalesce(email, ''), '@', 1));
  s := translate(s, 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ', 'aaaaaaceeeeiiiinooooouuuuyy');
  s := regexp_replace(s, '[^a-z0-9._-]', '', 'g');
  s := btrim(s, '.');
  s := btrim(left(s, 40), '.');
  if s = '' then return 'user'; end if;
  if length(s) < 3 then return 'user.' || s; end if;
  return s;
end $$;

-- The first free username for an email: the base, then base2, base3, ... Callers in a
-- transaction get an advisory lock so two inserts cannot pick the same one.
create or replace function xt_make_username(email text) returns text language plpgsql as $$
declare base text := xt_username_base(email); n integer := 1; cand text;
begin
  perform pg_advisory_xact_lock(hashtextextended('xt_username', 0));
  loop
    if n = 1 then
      cand := base;
    else
      cand := rtrim(left(base, 40 - length(n::text)), '.') || n::text;
    end if;
    exit when not exists (select 1 from person where lower(username) = cand);
    n := n + 1;
  end loop;
  return cand;
end $$;

-- Existing people, in a fixed order (email, then id) so a rerun on the same data gives the same names.
do $$
declare r record;
begin
  for r in select id, email from person where username is null order by lower(email) nulls last, id loop
    update person set username = xt_make_username(r.email) where id = r.id;
  end loop;
end $$;

create or replace function xt_person_username_default() returns trigger language plpgsql as $$
begin
  if new.username is null then
    new.username := xt_make_username(new.email);
  end if;
  return new;
end $$;

drop trigger if exists person_username_default on person;
create trigger person_username_default before insert on person
  for each row execute function xt_person_username_default();

alter table person alter column username set not null;
create unique index if not exists person_username_key on person (lower(username));

do $$
begin
  alter table person add constraint person_username_ck
    check (username ~ '^[a-z0-9._-]{3,40}$');
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table person add constraint person_session_epoch_ck check (session_epoch >= 0);
exception when duplicate_object then null;
end $$;

-- One row per wrong sign-in attempt (and per attempt in flight). username_key is the lowercased
-- name that was typed, whether or not it exists; ip is the client address key. No password.
create table if not exists login_failure (
  id           bigint generated always as identity primary key,
  username_key text        not null,
  ip           text        not null,
  at           timestamptz not null default now()
);
-- (13-hashed-keys.sql later replaces this table: column ip becomes address_key. The indexes on ip
-- are only made while that column exists, so this file still runs twice after 13.)
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'login_failure' and column_name = 'ip') then
    create index if not exists login_failure_user_idx on login_failure (username_key, at);
    create index if not exists login_failure_ip_idx   on login_failure (ip, at);
    create index if not exists login_failure_at_idx   on login_failure (at);
  end if;
end $$;

-- Who set, changed, reset or removed a password. kind: change (the person), reset and remove (a
-- manager, issued_by), cli (the server command, no issuer). Never a password or a hash.
create table if not exists password_audit (
  id         bigint generated always as identity primary key,
  person_id  uuid        not null references person(id) on delete cascade,
  issued_by  uuid        references person(id) on delete set null,
  kind       text        not null,
  at         timestamptz not null default now(),
  constraint password_audit_kind_ck check (kind in ('change', 'reset', 'remove', 'cli'))
);
create index if not exists password_audit_issuer_idx on password_audit (issued_by, at);
create index if not exists password_audit_person_idx on password_audit (person_id, at);

-- Housekeeping: the old body plus old sign-in failures (the limits look back 15 minutes only).
create or replace function xt_purge_expired() returns integer language plpgsql as $$
declare n integer := 0; k integer;
begin
  delete from login_token where expires_at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_attempt where at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  delete from login_failure where at < now() - interval '1 day';
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

insert into schema_migration (file) values ('12-passwords.sql') on conflict do nothing;

commit;
