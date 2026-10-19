import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xynotransit_app/domain/common_passwords.dart';
import 'package:xynotransit_app/domain/password_rules.dart';

void main() {
  const who = (
    username: 'rosa.rakoto',
    email: 'Rosa.Rakoto@Example.org',
    name: 'Rosa Rakoto Andrianaivo',
  );
  String? check(String p) => PasswordRules.check(
    p,
    username: who.username,
    email: who.email,
    fullName: who.name,
  );

  group('password policy', () {
    final cases = <(String, String?)>[
      ('', PasswordRules.tooShort),
      ('123456789', PasswordRules.tooShort),
      ('short one', PasswordRules.tooShort),
      ('tab\there is long', PasswordRules.hasControl),
      ('new\nline is long', PasswordRules.hasControl),
      ('nul\u0000 is long enough', PasswordRules.hasControl),
      ('\u007fdelete is long', PasswordRules.hasControl),
      // A control character wins over the length.
      ('\t', PasswordRules.hasControl),
      ('x' * 129, PasswordRules.tooLong),
      ('é' * 129, PasswordRules.tooLong),
      ('ROSA.RAKOTO', PasswordRules.looksLikeYou),
      ('rosa.rakoto@example.org', PasswordRules.looksLikeYou),
      ('Rosa Rakoto Andrianaivo', PasswordRules.looksLikeYou),
      ('rosa rakoto andrianaivo', PasswordRules.looksLikeYou),
      ('aaaaaaaaaa', PasswordRules.repeated),
      ('          ', PasswordRules.repeated),
      ('1234567890', PasswordRules.simpleRun),
      ('0123456789', PasswordRules.simpleRun),
      ('9876543210', PasswordRules.simpleRun),
      ('abcdefghij', PasswordRules.simpleRun),
      ('ABCDEFGHIJ', PasswordRules.simpleRun),
      ('jihgfedcba', PasswordRules.simpleRun),
      ('123456789012', PasswordRules.simpleRun),
      ('password123', PasswordRules.tooCommon),
      ('PassWord123', PasswordRules.tooCommon),
      ('Qwertyuiop', PasswordRules.tooCommon),
      ('iloveyou123', PasswordRules.tooCommon),
      ('1234567891', PasswordRules.tooCommon),
      ('correct horse battery', null),
      ('a b c d e f g h', null),
      ('  leading spaces kept  ', null),
      ('tenchars!!', null),
      ('abcdefghik', null),
      ('1234567809', null),
      ('12345678901', PasswordRules.simpleRun),
      ('x7!' * 42, null),
      ('${'x' * 127}y', null),
    ];
    for (final (pw, want) in cases) {
      test(
        '${pw.length > 24 ? '${pw.substring(0, 24)}...' : pw.replaceAll('\n', r'\n').replaceAll('\t', r'\t').replaceAll('\u0000', r'\0').replaceAll('\u007f', r'\x7f')} -> ${want ?? 'ok'}',
        () {
          expect(check(pw), want);
        },
      );
    }

    test('spaces count and are never trimmed', () {
      // Ten characters only because of the spaces.
      expect(check('  ab cd   '), isNull);
      expect(check('ab cd'), PasswordRules.tooShort);
      expect(
        PasswordRules.check('longusername', username: 'longusername'),
        PasswordRules.looksLikeYou,
      );
      expect(
        PasswordRules.check(' longusername', username: 'longusername'),
        isNull,
      );
    });

    test('length counts characters, not UTF-16 units', () {
      const nine = '😀😁😂🤣😃😄😅😆😉';
      expect(nine.length, greaterThan(9));
      expect(check(nine), PasswordRules.tooShort);
      expect(check('$nine😊'), isNull);
      final max = 'é' * 64 + 'è' * 64;
      expect(check(max), isNull);
      expect(check('${max}e'), PasswordRules.tooLong);
      // A combining sequence counts every character.
      expect(check('é' * 5), isNull);
    });

    test('empty person fields never match', () {
      expect(PasswordRules.check('some fine passphrase'), isNull);
      expect(PasswordRules.check('q' * 10), PasswordRules.repeated);
    });

    test('the local part of an address without a domain', () {
      expect(
        PasswordRules.check(
          'weirdaddress',
          username: 'x',
          email: 'weirdaddress',
        ),
        PasswordRules.looksLikeYou,
      );
    });

    test('messages are plain and have no dash characters', () {
      for (final m in [
        PasswordRules.tooShort,
        PasswordRules.tooLong,
        PasswordRules.hasControl,
        PasswordRules.looksLikeYou,
        PasswordRules.repeated,
        PasswordRules.simpleRun,
        PasswordRules.tooCommon,
        PasswordRules.mismatch,
        PasswordRules.currentWrong,
        PasswordRules.wrongLogin,
        PasswordRules.tooManyAttempts,
        PasswordRules.mustChangeFirst,
        PasswordRules.signInAgain,
        UsernameRules.invalid,
        UsernameRules.taken,
      ]) {
        expect(m, isNot(contains(String.fromCharCode(0x2014))));
        expect(m, endsWith('.'));
      }
      expect(PasswordRules.tooShort, 'Use at least 10 characters.');
      expect(
        PasswordRules.tooCommon,
        'That password is too common. Pick something only you would think of.',
      );
    });
  });

  group('the common password list', () {
    test('has at least 300 entries, lower case, 10 or more characters', () {
      expect(commonPasswords.length, greaterThanOrEqualTo(300));
      for (final p in commonPasswords) {
        expect(p, p.toLowerCase());
        expect(p, p.trim());
        expect(p.runes.length, greaterThanOrEqualTo(10), reason: p);
      }
    });

    test('is the list the API ships', () {
      final f = File('../xynotransit-api/src/common_passwords.txt');
      if (!f.existsSync()) {
        markTestSkipped('the API list is not in this checkout');
        return;
      }
      final api = f
          .readAsLinesSync()
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toSet();
      expect(commonPasswords, api);
    });
  });

  group('strength meter', () {
    test('only length and common-ness count', () {
      PasswordStrength s(String p) => PasswordRules.strength(p);
      expect(s(''), PasswordStrength.empty);
      expect(s('Ab1!'), PasswordStrength.tooShort);
      expect(s('password123'), PasswordStrength.weak);
      expect(s('1234567890'), PasswordStrength.weak);
      expect(s('aaaaaaaaaaaa'), PasswordStrength.weak);
      expect(s('a purple bicycle'), PasswordStrength.good);
      expect(s('lowercase pw'), PasswordStrength.fair);
      // No credit for letters and symbols: same length, same level.
      expect(s('abcdefghik'), s('Zq9!Zq9!Zq'));
      expect(s('${'correct horse ' * 2}battery'), PasswordStrength.strong);
    });
  });

  group('usernames', () {
    test('clean accepts the allowed set and lowers the case', () {
      expect(UsernameRules.clean(' Rosa.Rakoto '), 'rosa.rakoto');
      expect(UsernameRules.clean('a_b-c.d9'), 'a_b-c.d9');
      expect(UsernameRules.clean('abc'), 'abc');
      expect(UsernameRules.clean('a' * 40), 'a' * 40);
    });

    test('clean refuses the rest', () {
      for (final bad in [
        '',
        'ab',
        'a' * 41,
        'rosa rakoto',
        'rosa@x',
        'rosé',
        'ro/sa',
        'ro\tsa',
      ]) {
        expect(UsernameRules.clean(bad), isNull, reason: bad);
      }
      expect(
        UsernameRules.invalid,
        'Usernames use letters, digits, dots, dashes and underscores, '
        '3 to 40 characters.',
      );
      expect(UsernameRules.taken, 'That username is already used.');
    });

    test(
      'the default is the local part of the email, numbered on conflict',
      () {
        final taken = <String>{};
        String make(String e) {
          final u = UsernameRules.fromEmail(e, taken.contains);
          taken.add(u);
          return u;
        }

        expect(make('Rosa.Rakoto@example.org'), 'rosa.rakoto');
        expect(make('rosa.rakoto@other.org'), 'rosa.rakoto2');
        expect(make('rosa.rakoto@third.org'), 'rosa.rakoto3');
        expect(make('Zoë+tag@example.org'), 'zotag');
        expect(make('a@b.org').length, greaterThanOrEqualTo(3));
        expect(make('${'x' * 60}@b.org').length, lessThanOrEqualTo(40));
      },
    );
  });
}
