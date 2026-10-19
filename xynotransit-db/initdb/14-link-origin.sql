-- Xynotransit: where a sign-in link came from, and whether it may be used to recover a password.
--
-- login_token gets two columns:
--   origin          'email' (asked for on the sign-in page, sent to the mailbox), 'admin' (a manager
--                   made it and handed it over) or 'cli' (the server command made it).
--   allow_recovery  true only when a session that begins with this link may choose a new password
--                   WITHOUT the current one. Email links prove control of the mailbox, so they
--                   allow it. Manager and server links do not, unless the person who made them
--                   asked for "recovery" (a link handed over in a chat may leak).
-- A person who has no password at all never needs the current password, whatever the link.
-- Existing rows: a row that matches a sign_in_link_audit row (same person, same expiry) was made
-- by a manager ('admin') or by the server command ('cli', no issuer); every other row came from a
-- sign-in page request ('email'). allow_recovery is true for 'email' rows only.
-- sign_in_link_audit records origin and recovery too. password_audit.kind gains 'change-lock' (the
-- sessions of a person ended after 10 wrong current passwords in 15 minutes).
-- Safe to run again: the backfill only runs when the columns are added. Applied files are never
-- edited; this one only adds.

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'login_token'
                   and column_name = 'origin') then
    -- The defaults are the careful ones: a row nobody labelled is a manager link without recovery.
    alter table login_token add column origin text not null default 'admin';
    alter table login_token add column allow_recovery boolean not null default false;
    update login_token t set origin = case
        when exists (select 1 from sign_in_link_audit a
                     where a.person_id = t.person_id and a.expires_at = t.expires_at
                       and a.issued_by is not null) then 'admin'
        when exists (select 1 from sign_in_link_audit a
                     where a.person_id = t.person_id and a.expires_at = t.expires_at) then 'cli'
        else 'email' end;
    update login_token set allow_recovery = (origin = 'email');
  end if;
end $$;

do $$
begin
  alter table login_token drop constraint if exists login_token_origin_ck;
  alter table login_token add constraint login_token_origin_ck
    check (origin in ('email', 'admin', 'cli'));
end $$;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'sign_in_link_audit'
                   and column_name = 'origin') then
    alter table sign_in_link_audit add column origin text not null default 'admin';
    alter table sign_in_link_audit add column recovery boolean not null default false;
    update sign_in_link_audit set origin = 'cli' where issued_by is null;
  end if;
  alter table sign_in_link_audit drop constraint if exists sign_in_link_audit_origin_ck;
  alter table sign_in_link_audit add constraint sign_in_link_audit_origin_ck
    check (origin in ('admin', 'cli'));
end $$;

do $$
begin
  alter table password_audit drop constraint if exists password_audit_kind_ck;
  alter table password_audit add constraint password_audit_kind_ck
    check (kind in ('change', 'change-via-link', 'change-lock', 'reset', 'remove', 'cli'));
end $$;

insert into schema_migration (file) values ('14-link-origin.sql') on conflict do nothing;

commit;
