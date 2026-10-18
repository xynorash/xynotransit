insert into team (code, name, sort) values ('tana', 'Tana', 1), ('abe', 'Antsirabe', 2);

insert into person (id, full_name, email, app_role, active) values
  ('00000000-0000-0000-0000-0000000000a1', 'Ana Rakoto',  'ana@example.org',  'contributor', true),
  ('00000000-0000-0000-0000-0000000000a2', 'Ben Rabe',    'ben@example.org',  'contributor', true),
  ('00000000-0000-0000-0000-0000000000a3', 'Cora Boss',   'cora@example.org', 'controller',  true),
  ('00000000-0000-0000-0000-0000000000a4', 'Dan Gone',    'dan@example.org',  'contributor', false);

-- Deck order is: ben (Tana 1), ana (Tana 2), cora (Antsirabe 1).
insert into assignment (id, code, person_id, team_id, role_title, sort, active) values
  ('00000000-0000-0000-0000-0000000000d1', 'ana-import', '00000000-0000-0000-0000-0000000000a1', 1, 'Import', 2, true),
  ('00000000-0000-0000-0000-0000000000d2', 'ben-export', '00000000-0000-0000-0000-0000000000a2', 1, 'Export', 1, true),
  ('00000000-0000-0000-0000-0000000000d3', 'cora-ops',   '00000000-0000-0000-0000-0000000000a3', 2, 'Operations', 1, true),
  ('00000000-0000-0000-0000-0000000000d4', 'dan-old',    '00000000-0000-0000-0000-0000000000a4', 2, 'Old seat', 2, false);

insert into metric_def (id, assignment_id, key, label, series, retired_at) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1', 'files', 'Files', 0, null),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000d1', 'calls', 'Calls', 1, null),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-0000000000d1', 'old',   'Old',   2, now()),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-0000000000d2', 'boxes', 'Boxes', 0, null);

insert into kpi_def (id, assignment_id, sort, text, retired_at) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1', 1, 'On time', null),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000d1', 2, 'No errors', null),
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000d1', 3, 'Retired target', now()),
  ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000d2', 1, 'Ship fast', null),
  ('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-0000000000d3', 1, 'Keep calm', null);
