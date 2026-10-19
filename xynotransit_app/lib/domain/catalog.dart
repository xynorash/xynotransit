import 'enums.dart';

class Team {
  const Team({
    required this.id,
    required this.code,
    required this.name,
    required this.sort,
  });
  final String id;
  final String code;
  final String name;
  final int sort;
}

class Person {
  const Person({
    required this.id,
    required this.fullName,
    this.email,
    this.appRole = AppRole.contributor,
    this.active = true,
  });
  final String id;
  final String fullName;
  final String? email;
  final AppRole appRole;
  final bool active;
}

class MetricDef {
  const MetricDef({
    required this.id,
    required this.key,
    required this.label,
    required this.series,
  });
  final String id;
  final String key;
  final String label;

  /// 0 blue, 1 orange, 2 green.
  final int series;
}

class KpiDef {
  const KpiDef({required this.id, required this.sort, required this.text});
  final String id;
  final int sort;
  final String text;
}

class Assignment {
  const Assignment({
    required this.id,
    required this.code,
    required this.personId,
    required this.teamId,
    required this.roleTitle,
    required this.sort,
    required this.metrics,
    required this.kpis,
    this.active = true,
  });
  final String id;
  final String code;
  final String personId;
  final String teamId;
  final String roleTitle;
  final int sort;
  final List<MetricDef> metrics;
  final List<KpiDef> kpis;
  final bool active;

  bool get hasCounts => metrics.isNotEmpty;
}

/// Everything that rarely changes. Assignments are kept in deck order
/// (team order, then running order inside the team).
class Catalog {
  Catalog({
    required List<Team> teams,
    required this.persons,
    required List<Assignment> assignments,
  }) : teams = List.unmodifiable(
         <Team>[...teams]..sort((a, b) => a.sort.compareTo(b.sort)),
       ),
       assignments = List.unmodifiable(_ordered(teams, assignments));

  final List<Team> teams;
  final List<Person> persons;
  final List<Assignment> assignments;

  static List<Assignment> _ordered(
    List<Team> teams,
    List<Assignment> assignments,
  ) {
    final teamSort = {for (final t in teams) t.id: t.sort};
    return [...assignments]..sort((a, b) {
      final c = (teamSort[a.teamId] ?? 0).compareTo(teamSort[b.teamId] ?? 0);
      return c != 0 ? c : a.sort.compareTo(b.sort);
    });
  }

  // Lookups by id are maps built once, so a catalog of hundreds of people
  // costs one step per question, not a scan of the whole list.
  late final Map<String, Assignment> _assignmentsById = {
    for (final a in assignments) a.id: a,
  };
  late final Map<String, Assignment> _assignmentsByCode = {
    for (final a in assignments) a.code: a,
  };
  late final Map<String, Team> _teamsById = {for (final t in teams) t.id: t};
  late final Map<String, Person> _personsById = {
    for (final p in persons) p.id: p,
  };
  late final Map<String, List<Assignment>> _byPerson = _group(
    (a) => a.personId,
  );
  late final Map<String, List<Assignment>> _byTeam = _group((a) => a.teamId);

  Map<String, List<Assignment>> _group(String Function(Assignment) key) {
    final m = <String, List<Assignment>>{};
    for (final a in assignments) {
      (m[key(a)] ??= []).add(a);
    }
    return m;
  }

  Assignment? assignmentById(String? id) => _assignmentsById[id];

  Assignment? assignmentByCode(String code) => _assignmentsByCode[code];

  Team? teamById(String? id) => _teamsById[id];

  Person? personById(String? id) => _personsById[id];

  Team teamOf(Assignment a) =>
      _teamsById[a.teamId] ??
      (throw StateError('No team ${a.teamId} for seat ${a.code}'));

  /// The person of a seat. A seat whose person the catalog does not list (the
  /// server hides switched off people) reads as an unknown person instead of
  /// breaking every screen that shows a name.
  Person personOf(Assignment a) =>
      _personsById[a.personId] ??
      Person(id: a.personId, fullName: 'Unknown person', active: false);

  List<Assignment> assignmentsOfPerson(String personId) =>
      List.of(_byPerson[personId] ?? const []);

  List<Assignment> assignmentsOfTeam(Team t) =>
      List.of(_byTeam[t.id] ?? const []);

  /// A seat is expected to report when the seat and its person are both
  /// switched on (the server counts the same way). A person the catalog does
  /// not list is a switched off one: the server hides those.
  bool isExpected(Assignment a) =>
      a.active && (_personsById[a.personId]?.active ?? false);

  /// How many seats are expected to report in a new period.
  int get expectedCount => assignments.where(isExpected).length;

  /// "Name · Role".
  String labelOf(Assignment a) => '${personOf(a).fullName} · ${a.roleTitle}';

  /// Number of distinct people (13) as opposed to assignments (14).
  int get peopleCount => assignments.map((a) => a.personId).toSet().length;
}
