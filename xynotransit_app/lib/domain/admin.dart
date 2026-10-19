import 'dart:convert';

import 'text_rules.dart';

/// What a manager types when defining the counts of a seat. [id] is null for a new one.
class MetricInput {
  const MetricInput({this.id, required this.label});
  final String? id;
  final String label;
}

/// What a manager types when defining the targets of a seat. [id] is null for a new one.
class KpiInput {
  const KpiInput({this.id, required this.text});
  final String? id;
  final String text;
}

/// Limits shared by the forms, the in-memory demo and the API.
abstract final class DefinitionRules {
  static const maxMetrics = 8;
  static const maxKpis = 10;
  static const maxMetricLabel = 60;
  static const maxKpiText = 200;
  static const maxRoleTitle = 80;
  static const maxName = 80;
}

/// A cleaned value, or the plain words saying why it is refused.
class Cleaned<T> {
  const Cleaned.ok(T this.value) : problem = null;
  const Cleaned.fail(String this.problem) : value = null;
  final T? value;
  final String? problem;
  bool get ok => problem == null;
}

/// What a manager may type, checked in the same order and with the same words
/// as the API (xynotransit-api/src/rules.rs). The in-memory demo uses these, and
/// the contract suite proves both backends answer alike.
abstract final class AdminRules {
  static const maxTeamName = 60;
  static const maxSort = 10000;
  static const maxEmail = 254;
  static const maxEmailLocal = 64;

  static const plainLine = 'Use plain text on one line.';
  static const emailInvalid = 'Enter a valid email address.';
  static const metricsTooMany = 'A seat can have at most 8 counts.';
  static const kpisTooMany = 'A seat can have at most 10 targets.';
  static const metricDuplicate =
      'Two counts have the same name. Give each count its own name.';
  static const notThisSeat =
      'One of the counts or targets does not belong to this seat.';
  static const teamNameTaken = 'That team name is already used.';
  static const emailTaken = 'That email is already used.';
  static const lastManager = 'There must be at least one manager.';
  static const seatTaken = 'That person already has this role in this team.';

  /// Trim, then 1..=[max] characters on one line.
  static Cleaned<String> cleanLine(
    String s,
    int max,
    String empty,
    String long,
  ) {
    final t = trimText(plainSpaces(s));
    if (t.isEmpty) return Cleaned.fail(empty);
    if (charCount(t) > max) return Cleaned.fail(long);
    if (hasHiddenChars(t)) return const Cleaned.fail(plainLine);
    return Cleaned.ok(t);
  }

  static Cleaned<String> cleanTeamName(String s) => cleanLine(
    s,
    maxTeamName,
    'Enter a team name.',
    'A team name can have at most 60 characters.',
  );

  static Cleaned<String> cleanPersonName(String s) => cleanLine(
    s,
    DefinitionRules.maxName,
    'Enter a name.',
    'A name can have at most 80 characters.',
  );

  static Cleaned<String> cleanRoleTitle(String s) => cleanLine(
    s,
    DefinitionRules.maxRoleTitle,
    'Enter a role title.',
    'A role title can have at most 80 characters.',
  );

  static const _mailBad = '<>(),;:\\"[]';

  /// Trimmed, lowercased, and shaped like name@domain.tld.
  static Cleaned<String> cleanEmail(String s) {
    final e = trimText(s).toLowerCase();
    const bad = Cleaned<String>.fail(emailInvalid);
    if (e.isEmpty || utf8.encode(e).length > maxEmail) return bad;
    final banned = _mailBad.runes.toSet();
    for (final c in e.runes) {
      if (isControlRune(c) ||
          isWhiteSpaceRune(c) ||
          isInvisibleRune(c) ||
          banned.contains(c)) {
        return bad;
      }
    }
    final at = e.indexOf('@');
    if (at < 0) return bad;
    final local = e.substring(0, at);
    final domain = e.substring(at + 1);
    final dotted =
        domain.contains('.') &&
        !domain.startsWith('.') &&
        !domain.endsWith('.') &&
        !domain.contains('..');
    if (local.isEmpty ||
        utf8.encode(local).length > maxEmailLocal ||
        domain.contains('@') ||
        !dotted) {
      return bad;
    }
    return Cleaned.ok(e);
  }

  /// 0..=8 counts, each named 1..=60 characters, names unique ignoring case.
  /// Returns the first problem, or null.
  static String? checkMetrics(List<MetricInput> metrics) {
    if (metrics.length > DefinitionRules.maxMetrics) return metricsTooMany;
    final names = <String>{};
    for (final m in metrics) {
      final c = cleanLine(
        m.label,
        DefinitionRules.maxMetricLabel,
        'Give every count a name.',
        'A count name can have at most 60 characters.',
      );
      if (!c.ok) return c.problem;
      if (!names.add(c.value!.toLowerCase())) return metricDuplicate;
    }
    return _twice(metrics.map((m) => m.id), 'count');
  }

  /// 0..=10 targets, each 1..=200 characters.
  static String? checkKpis(List<KpiInput> kpis) {
    if (kpis.length > DefinitionRules.maxKpis) return kpisTooMany;
    for (final k in kpis) {
      final c = cleanLine(
        k.text,
        DefinitionRules.maxKpiText,
        'Write every target in words.',
        'A target can have at most 200 characters.',
      );
      if (!c.ok) return c.problem;
    }
    return _twice(kpis.map((k) => k.id), 'target');
  }

  static String? _twice(Iterable<String?> ids, String what) {
    final seen = <String>{};
    for (final id in ids) {
      if (id != null && !seen.add(id)) {
        return 'The same $what is listed twice.';
      }
    }
    return null;
  }

  /// A date in the years 2000 to 2100, as a date only value, else the plain words.
  static Cleaned<DateTime> checkDate(DateTime d) =>
      d.year < 2000 || d.year > 2100
      ? const Cleaned.fail('Enter a date between 2000 and 2100.')
      : Cleaned.ok(DateTime(d.year, d.month, d.day));
}
