import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/text_rules.dart';

void main() {
  group('internalLocalOf', () {
    const cases = {
      'Rosa Rakoto': 'rosa.rakoto',
      '  Rosa   Rakoto  ': 'rosa.rakoto',
      'ROSA RAKOTO': 'rosa.rakoto',
      'Hanitra Rakotoarisoa-Andria': 'hanitra.rakotoarisoaandria',
      "Seán O'Brien": 'sean.obrien',
      'José Ñandú': 'jose.nandu',
      'Zoë Müller': 'zoe.muller',
      'Straße Weiß': 'strasse.weiss',
      'Rosa. R.': 'rosa.r',
      'Rosa..Rakoto': 'rosa.rakoto',
      '.Rosa.': 'rosa',
      'Agent 007': 'agent.007',
      'R2-D2 (droid)': 'r2d2.droid',
      'Rosa\tRakoto\nTwo': 'rosa.rakoto.two',
      'a_b+c@d': 'abcd',
      '李明': 'user',
      '': 'user',
      '...': 'user',
      '!!!': 'user',
    };
    cases.forEach((name, local) {
      test('"$name" gives $local', () => expect(internalLocalOf(name), local));
    });

    test('at most 40 characters and no dot at the end', () {
      final long = internalLocalOf(
        'Abcdefghijklmnopqrstuvwxyz Abcdefghijklmnopqrstuvwxyz',
      );
      expect(long.length, lessThanOrEqualTo(40));
      expect(long, 'abcdefghijklmnopqrstuvwxyz.abcdefghijklm');
      // A cut that lands right after a dot drops the dot.
      final cutAtDot = internalLocalOf('${'a' * 39} bcd');
      expect(cutAtDot, 'a' * 39);
    });

    test('only lower case ASCII letters, digits and single dots', () {
      final ok = RegExp(r'^[a-z0-9]+(\.[a-z0-9]+)*$');
      for (final n in [
        'Çağrı Öztürk',
        'Łukasz Żółć',
        'Ana-María de la Cruz Jr.',
      ]) {
        expect(internalLocalOf(n), matches(ok), reason: n);
      }
    });
  });

  group('internalEmailOf', () {
    test('adds the domain', () {
      expect(
        internalEmailOf('Rosa Rakoto', 'xynotransit.internal', (_) => false),
        'rosa.rakoto@xynotransit.internal',
      );
    });

    test('numbers a conflict: rosa.rakoto, rosa.rakoto2, rosa.rakoto3', () {
      final used = <String>{};
      final made = <String>[];
      for (var i = 0; i < 3; i++) {
        final e = internalEmailOf(
          'Rosa Rakoto',
          'xynotransit.internal',
          used.contains,
        );
        used.add(e);
        made.add(e);
      }
      expect(made, [
        'rosa.rakoto@xynotransit.internal',
        'rosa.rakoto2@xynotransit.internal',
        'rosa.rakoto3@xynotransit.internal',
      ]);
    });

    test('a number keeps the local part within 40 characters', () {
      final base = '${'a' * 38}.b';
      expect(internalLocalOf(base).length, 40);
      final used = {'${internalLocalOf(base)}@x.internal'};
      final e = internalEmailOf(base, 'x.internal', used.contains);
      expect(e.split('@').first.length, lessThanOrEqualTo(40));
      expect(e, endsWith('2@x.internal'));
    });

    test('a number after a cut never leaves a dot before it', () {
      final used = {'${'a' * 39}@x.internal'};
      final e = internalEmailOf('${'a' * 39} bcd', 'x.internal', used.contains);
      expect(e, '${'a' * 39}2@x.internal');
      expect(e.split('@').first.length, 40);
    });
  });
}
