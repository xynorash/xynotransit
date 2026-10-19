-- Xynotransit: one seat per person, team and role title, ignoring case and outer spaces.
-- The table already refuses an exact repeat (unique (person_id, team_id, role_title)); this closes
-- "Import" versus "import " as well. Safe to run again. When old rows already repeat a title the
-- index is skipped with a WARNING and the rows are left alone (the API checks the same rule).

begin;

do $$
begin
  if exists (select 1 from pg_class where relname = 'assignment_role_lower_uq'
             and relnamespace = 'public'::regnamespace) then
    return;
  end if;
  begin
    create unique index assignment_role_lower_uq
      on assignment (person_id, team_id, lower(btrim(role_title)));
  exception when unique_violation then
    raise warning 'unique index assignment_role_lower_uq skipped: old seats already repeat a role title';
  end;
end $$;

insert into schema_migration (file) values ('08-role-title-unique.sql') on conflict do nothing;

commit;
