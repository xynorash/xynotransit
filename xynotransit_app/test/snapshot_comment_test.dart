import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/domain/snapshot.dart';

void main() {
  test('a target comment survives JSON and is trimmed', () {
    final t = SnapshotTarget.fromJson({
      'text': 'On time',
      'status': 'partly',
      'comment': '  Port strike  ',
    });
    expect(t.comment, 'Port strike');
    expect(t.toJson()['comment'], 'Port strike');
    expect(t.status, KpiStatus.partly);
  });

  test('old snapshots without a comment, and blank comments, give null', () {
    final old = SnapshotTarget.fromJson({'text': 'A', 'status': 'met'});
    expect(old.comment, isNull);
    expect(old.toJson().containsKey('comment'), isFalse);
    final blank = SnapshotTarget.fromJson({
      'text': 'A',
      'status': 'met',
      'comment': '   ',
    });
    expect(blank.comment, isNull);
  });
}
