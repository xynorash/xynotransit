import '../../domain/catalog.dart';
import '../../domain/report.dart';

/// How many reports are in, by the rule every manager view shares:
/// `expected` is the active seats of active people, `submitted` counts only
/// reports of those seats (so it never passes `expected`), and `switchedOff`
/// counts sent reports of seats or people that are switched off now. Those are
/// real reports, never expected and never missing.
class ReportCounts {
  const ReportCounts({
    required this.expected,
    required this.submitted,
    required this.switchedOff,
  });

  final int expected;
  final int submitted;
  final int switchedOff;

  /// [catalog] must list the switched-off seats too.
  factory ReportCounts.of(Catalog catalog, Iterable<Report> reports) {
    final sent = <String>{
      for (final r in reports)
        if (r.isSubmitted) r.assignmentId,
    };
    var submitted = 0;
    var off = 0;
    for (final id in sent) {
      final a = catalog.assignmentById(id);
      if (a == null) continue;
      if (catalog.isExpected(a)) {
        submitted++;
      } else {
        off++;
      }
    }
    return ReportCounts(
      expected: catalog.expectedCount,
      submitted: submitted,
      switchedOff: off,
    );
  }

  /// "plus 1 from a switched-off person", or empty when there are none.
  String get switchedOffNote => switchedOffPhrase(switchedOff);
}

/// "plus 1 from a switched-off person" / "plus 2 from switched-off people".
String switchedOffPhrase(int k) => k <= 0
    ? ''
    : 'plus $k from ${k == 1 ? 'a switched-off person' : 'switched-off people'}';

/// How a seat is named in a list: the person's name, and the seat title too
/// when that person has more than one seat, so two seats never look the same.
String seatName(Catalog catalog, Assignment a) {
  final name = catalog.personOf(a).fullName;
  return catalog.assignmentsOfPerson(a.personId).length > 1
      ? '$name · ${a.roleTitle}'
      : name;
}
