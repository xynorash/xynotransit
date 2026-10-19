-- Xynotransit: sign in without a real email.
-- A manager (or the server command `xynotransit-api sign-in-link`) creates a one-time sign-in
-- link for a person. The link is an ordinary row of login_token (only the SHA-256 of the token is
-- stored, same /auth/verify exchange as a magic link, just a longer life). This file adds the
-- audit trail: who got a link, who issued it, when, and until when. The token is never stored here.
-- Safe to run again. login_token is unchanged, so old rows stay valid.

begin;

create table if not exists sign_in_link_audit (
  id         bigint generated always as identity primary key,
  person_id  uuid        not null references person(id) on delete cascade,
  -- The manager who issued it; null when it came from the server command.
  issued_by  uuid        references person(id) on delete set null,
  issued_at  timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint sign_in_link_audit_expiry_ck check (expires_at > issued_at)
);
create index if not exists sign_in_link_audit_issuer_idx
  on sign_in_link_audit (issued_by, issued_at);
create index if not exists sign_in_link_audit_person_idx
  on sign_in_link_audit (person_id, issued_at);

insert into schema_migration (file) values ('10-internal-signin.sql') on conflict do nothing;

commit;
