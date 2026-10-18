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

  Assignment? assignmentById(String? id) {
    for (final a in assignments) {
      if (a.id == id) return a;
    }
    return null;
  }

  Assignment? assignmentByCode(String code) {
    for (final a in assignments) {
      if (a.code == code) return a;
    }
    return null;
  }

  Team teamOf(Assignment a) => teams.firstWhere((t) => t.id == a.teamId);

  Person personOf(Assignment a) =>
      persons.firstWhere((p) => p.id == a.personId);

  List<Assignment> assignmentsOfPerson(String personId) =>
      assignments.where((a) => a.personId == personId).toList();

  List<Assignment> assignmentsOfTeam(Team t) =>
      assignments.where((a) => a.teamId == t.id).toList();

  /// "Name · Role".
  String labelOf(Assignment a) => '${personOf(a).fullName} · ${a.roleTitle}';

  /// Number of distinct people (13) as opposed to assignments (14).
  int get peopleCount => assignments.map((a) => a.personId).toSet().length;
}
