import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xynotransit_app/app/providers.dart';
import 'package:xynotransit_app/core/format.dart';
import 'package:xynotransit_app/core/theme/theme.dart';
import 'package:xynotransit_app/data/memory_repository.dart';
import 'package:xynotransit_app/data/repository.dart';
import 'package:xynotransit_app/domain/catalog.dart';
import 'package:xynotransit_app/domain/enums.dart';
import 'package:xynotransit_app/features/admin/people_screen.dart';
import 'package:xynotransit_app/features/admin/qr_view.dart';
import 'package:xynotransit_app/features/sign_in_screen.dart';

import '../admin_test.dart' show tapText, typeKey;
import '../helpers.dart';

Catalog catalogWithPeople() => Catalog(
  teams: const [Team(id: 't1', code: 'ops', name: 'Operations', sort: 1)],
  persons: const [
    Person(
      id: 'ana',
      fullName: 'Ana Boss',
      email: 'ana@example.com',
      appRole: AppRole.controller,
    ),
    Person(
      id: 'carol',
      fullName: 'Carol Rakoto',
      email: 'carol.rakoto@xynotransit.internal',
      appRole: AppRole.contributor,
    ),
    Person(
      id: 'bob',
      fullName: 'Bob Gone',
      email: 'bob@example.com',
      appRole: AppRole.contributor,
      active: false,
    ),
  ],
  assignments: const [],
);

class FailingRepo extends MemoryRepository {
  FailingRepo(Catalog c)
    : super(catalog: c, currentUser: () => DemoAuth.controller);
  Object? failWith;
  Completer<void>? hold;
  @override
  Future<SignInLink> createSignInLink(
    String personId, {
    int hours = 24,
    bool recovery = false,
  }) async {
    await hold?.future;
    final f = failWith;
    if (f != null) throw f;
    return super.createSignInLink(personId, hours: hours, recovery: recovery);
  }
}

Future<(MemoryRepository, ProviderContainer)> pump(
  WidgetTester tester, {
  MemoryRepository? repo,
  Size size = const Size(1200, 3000),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final cat = catalogWithPeople();
  final r =
      repo ??
      MemoryRepository(
        catalog: cat,
        currentUser: () => DemoAuth.controller,
        clock: () => DateTime(2026, 6, 1, 9, 5),
      );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      repositoryProvider.overrideWithValue(r),
      authServiceProvider.overrideWithValue(DemoAuth(cat)),
      initialStartProvider.overrideWithValue(MemoryRepository.demoStart),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PeopleScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (r, container);
}

Finder get linkButton => find.widgetWithText(FilledButton, 'Sign-in link');
final urlField = find.byKey(const Key('sign-in-link-url'));

String shownUrl(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: urlField, matching: find.byType(EditableText)),
    )
    .controller
    .text;

/// The People list builds lazily: scroll until [f] exists.
Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> openFor(WidgetTester tester, String name) async {
  final f = find.bySemanticsLabel('Sign-in link for $name');
  await reveal(tester, f);
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

/// A widget test with the semantics tree on, so labels can be found.
void uiTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

void main() {
  setUpAll(loadAppFonts);

  group('Add a person without an email', () {
    uiTest('empty email: the generated address is shown', (tester) async {
      final (repo, _) = await pump(tester);
      await tapText(tester, 'Add a person');
      expect(
        find.text(
          'Leave empty to create an internal address (no real email needed)',
        ),
        findsOneWidget,
      );
      expect(find.text('Email (optional)'), findsOneWidget);
      await typeKey(tester, 'person-name', 'Rosa Rakoto');
      await tapText(tester, 'Add person');
      expect(find.text('Saved.'), findsOneWidget);
      expect(find.byKey(const Key('generated-address')), findsOneWidget);
      expect(
        find.textContaining('rosa.rakoto@xynotransit.internal'),
        findsWidgets,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('person-email')),
      );
      expect(field.controller!.text, 'rosa.rakoto@xynotransit.internal');
      final c = await repo.loadCatalog();
      expect(
        c.persons.map((p) => p.email),
        contains('rosa.rakoto@xynotransit.internal'),
      );
    });

    uiTest('the same name twice gets a number', (tester) async {
      await pump(tester);
      for (var i = 0; i < 2; i++) {
        await tapText(tester, 'Add a person');
        await typeKey(tester, 'person-name', 'Rosa Rakoto');
        await tapText(tester, 'Add person');
        await tester.tap(find.byTooltip('Close').last);
        await tester.pumpAndSettle();
      }
      expect(find.text('rosa.rakoto2@xynotransit.internal'), findsOneWidget);
    });

    uiTest('a typed email is kept and no address is announced', (tester) async {
      await pump(tester);
      await tapText(tester, 'Add a person');
      await typeKey(tester, 'person-name', 'Dan');
      await typeKey(tester, 'person-email', 'dan@example.com');
      await tapText(tester, 'Add person');
      expect(find.byKey(const Key('generated-address')), findsNothing);
    });

    uiTest('editing still needs an email', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Edit Carol Rakoto'));
      await tester.pumpAndSettle();
      expect(find.text('Email (they sign in with it)'), findsOneWidget);
      await typeKey(tester, 'person-email', '');
      await tapText(tester, 'Save person');
      expect(find.text('Enter the email they sign in with.'), findsOneWidget);
    });
  });

  group('Sign-in link dialog', () {
    uiTest(
      'each person has the action; switched off ones are disabled with the reason',
      (tester) async {
        await pump(tester);
        expect(find.text('Carol Rakoto'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Sign-in link for Ana Boss'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Sign-in link for Carol Rakoto'),
          findsOneWidget,
        );
        // Bob is switched off and hidden until we ask for inactive people.
        await tester.tap(find.byKey(const Key('show-inactive')));
        await tester.pumpAndSettle();
        expect(find.text('Bob Gone'), findsOneWidget);
        const reason =
            'Switched off. Turn this person on in Edit person to make a link.';
        expect(find.text(reason), findsOneWidget);
        final bob = find.bySemanticsLabel(
          RegExp(r'^Sign-in link for Bob Gone, not available'),
        );
        expect(bob, findsOneWidget);
        expect(
          tester.getSemantics(bob).flagsCollection.isEnabled.toString(),
          isNot(contains('true')),
        );
        await tester.tap(bob, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Sign-in link for Bob Gone'), findsNothing);
      },
    );

    uiTest('choose, create, then link, QR, expiry, sentence and warning', (
      tester,
    ) async {
      final (repo, _) = await pump(tester);
      await openFor(tester, 'Carol Rakoto');
      expect(find.text('Sign-in link for Carol Rakoto'), findsOneWidget);
      for (final l in ['1 hour', '24 hours', '7 days']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.text('Create link'), findsOneWidget);
      expect(
        find.textContaining('does not turn off the ones you made before'),
        findsOneWidget,
        reason: 'says that another link does not revoke the first',
      );
      expect(urlField, findsNothing);
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();

      final url = shownUrl(tester);
      expect(url, startsWith('https://demo.invalid/auth/verify?token=demo-'));
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: urlField, matching: find.byType(TextField)),
            )
            .readOnly,
        isTrue,
      );
      expect(
        find.text(
          'Works until ${longDateTime(DateTime(2026, 6, 8, 9, 5))}, or until it is used.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Works until Monday 08 June 2026, 09:05, or until it is used.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Open this link to sign in to Xynotransit: $url'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Anyone who has this link can sign in as Carol Rakoto until it is '
          'used or it expires. Share it privately.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Making another link does not turn this one off.'),
        findsOneWidget,
      );
      expect(find.byType(QrView), findsOneWidget);
      expect(
        find.bySemanticsLabel('QR code of the sign-in link'),
        findsOneWidget,
      );
      expect(tester.widget<QrView>(find.byType(QrView)).data, url);
      // The link works once, in the repository the app uses.
      expect(repo.redeemSignInLink(url).personId, 'carol');
    });

    uiTest('Copy puts the link on the clipboard and says Copied', (
      tester,
    ) async {
      final clip = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clip.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pump(tester);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(find.text('Copied'), findsNothing);
      final url = shownUrl(tester);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(clip, [url]);
      expect(find.text('Copied'), findsOneWidget);
      // It is a live region, so a screen reader says it.
      final node = tester.getSemantics(find.text('Copied'));
      expect(node.flagsCollection.isLiveRegion.toString(), contains('true'));
      await tester.tap(find.text('Copy message'));
      await tester.pumpAndSettle();
      expect(clip.last, 'Open this link to sign in to Xynotransit: $url');
      expect(find.text('Copied'), findsOneWidget, reason: 'one note at a time');
    });

    uiTest('a second link is another link, and the first still works', (
      tester,
    ) async {
      final (repo, _) = await pump(tester);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      final first = shownUrl(tester);
      await tester.tap(find.text('Make another link'));
      await tester.pumpAndSettle();
      expect(urlField, findsNothing);
      await tester.tap(find.text('1 hour'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      final second = shownUrl(tester);
      expect(second, isNot(first));
      expect(
        find.text(
          'Works until Monday 01 June 2026, 10:05, or until it is used.',
        ),
        findsOneWidget,
      );
      expect(repo.redeemSignInLink(first).personId, 'carol');
      expect(repo.redeemSignInLink(second).personId, 'carol');
    });

    uiTest('a refusal is said in plain words and the dialog stays', (
      tester,
    ) async {
      final repo = FailingRepo(catalogWithPeople())
        ..failWith = const RepositoryException(
          'Too many sign-in links created. Try again later.',
        );
      await pump(tester, repo: repo);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(
        find.text('Too many sign-in links created. Try again later.'),
        findsOneWidget,
      );
      expect(urlField, findsNothing);
      repo.failWith = const NetworkException();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(
        find.text('No connection. Check your internet and try again.'),
        findsOneWidget,
      );
      repo.failWith = null;
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(urlField, findsOneWidget);
    });

    uiTest('while creating, Create link cannot be pressed twice', (
      tester,
    ) async {
      final repo = FailingRepo(catalogWithPeople())..hold = Completer<void>();
      await pump(tester, repo: repo);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.text('Create link'));
      await tester.pump();
      expect(find.text('Creating…'), findsOneWidget);
      final b = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Creating…'),
      );
      expect(b.onPressed, isNull);
      repo.hold!.complete();
      await tester.pumpAndSettle();
      expect(urlField, findsOneWidget);
    });

    uiTest(
      'focus: the dialog takes focus, the link field gets it after creating, Escape closes',
      (tester) async {
        await pump(tester);
        await openFor(tester, 'Carol Rakoto');
        final chip = tester.widget<ChoiceChip>(
          find.byKey(const Key('validity-24')),
        );
        expect(chip.autofocus, isTrue);
        expect(chip.selected, isTrue);
        expect(FocusManager.instance.primaryFocus, isNotNull);
        await tester.tap(find.text('Create link'));
        await tester.pumpAndSettle();
        final field = tester.widget<EditableText>(
          find.descendant(of: urlField, matching: find.byType(EditableText)),
        );
        expect(field.focusNode.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Sign-in link for Carol Rakoto'), findsNothing);
        expect(find.text('People and what they report'), findsOneWidget);
      },
    );

    uiTest('Close and Done close it', (tester) async {
      await pump(tester);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in link for Carol Rakoto'), findsNothing);
      await openFor(tester, 'Carol Rakoto');
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Sign-in link for Carol Rakoto'), findsNothing);
    });

    uiTest('the person editor offers the same dialog', (tester) async {
      await pump(tester);
      await tester.tap(find.bySemanticsLabel('Edit Carol Rakoto'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.bySemanticsLabel('Sign-in link for Carol Rakoto').last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Create link'), findsOneWidget);
    });
  });

  group('Recovery link option', () {
    MemoryRepository withPassword() {
      final r = MemoryRepository(
        catalog: catalogWithPeople(),
        currentUser: () => DemoAuth.controller,
        clock: () => DateTime(2026, 6, 1, 9, 5),
      );
      return r;
    }

    Future<void> givePassword(MemoryRepository r) async {
      final t = await r.resetPassword('carol');
      r.changePasswordOf(
        r.sessionFor('carol'),
        currentPassword: t.password,
        newPassword: 'a purple bicycle',
      );
    }

    const label =
        'Recovery link: lets them choose a new password without knowing the '
        'old one';
    const help =
        'Use it when they forgot their password and you are sure the link '
        'reaches only them. Otherwise use Reset password.';
    final box = find.descendant(
      of: find.byKey(const Key('recovery-choice')),
      matching: find.byType(Checkbox),
    );

    uiTest('a person without a password has no such choice', (tester) async {
      await pump(tester);
      await openFor(tester, 'Carol Rakoto');
      expect(box, findsNothing);
      expect(find.text(label), findsNothing);
    });

    uiTest('a person with a password: off by default, with its sentence', (
      tester,
    ) async {
      final r = withPassword();
      await givePassword(r);
      await pump(tester, repo: r);
      await openFor(tester, 'Carol Rakoto');
      expect(find.text(label), findsOneWidget);
      expect(find.text(help), findsOneWidget);
      expect(tester.widget<Checkbox>(box).value, isFalse);
      // The checkbox is one control with its words for a screen reader.
      expect(
        find.bySemanticsLabel(RegExp('Recovery link: lets them choose')),
        findsWidgets,
      );
      await tester.ensureVisible(find.text('Create link'));
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Anyone who has this link can sign in as Carol'),
        findsOneWidget,
      );
      expect(find.textContaining('choose a new password'), findsNothing);
      // The same box is there again for the next link.
      await tester.ensureVisible(find.text('Make another link'));
      await tester.tap(find.text('Make another link'));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(box).value, isFalse);
    });

    uiTest('ticking it sends recovery and warns in plain words', (
      tester,
    ) async {
      final r = withPassword();
      await givePassword(r);
      await pump(tester, repo: r);
      await openFor(tester, 'Carol Rakoto');
      await tester.ensureVisible(box);
      await tester.tap(box);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(box).value, isTrue);
      await tester.ensureVisible(find.text('Create link'));
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(find.textContaining('and choose a new password'), findsOneWidget);
      final url = shownUrl(tester);
      // The demo link carries it: the session can skip the old password.
      final session = r.redeemSignInLink(url);
      expect(r.refreshed(session).recentLinkSession, isTrue);
    });

    uiTest('tapping the words ticks it too', (tester) async {
      final r = withPassword();
      await givePassword(r);
      await pump(tester, repo: r);
      await openFor(tester, 'Carol Rakoto');
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(box).value, isTrue);
    });

    for (final e in {
      '360x800': const Size(360, 800),
      '800x1100': const Size(800, 1100),
      '1500x900': const Size(1500, 900),
    }.entries) {
      for (final scale in [1.0, 2.0]) {
        uiTest('no overflow at ${e.key} text x$scale', (tester) async {
          final r = withPassword();
          await givePassword(r);
          await pump(tester, repo: r, size: e.value, textScale: scale);
          await openFor(tester, 'Carol Rakoto');
          expect(tester.takeException(), isNull, reason: 'choose step');
          await tester.ensureVisible(box);
          await tester.tap(box);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Create link'));
          await tester.tap(find.text('Create link'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'result step');
        });
      }
    }
  });

  group('no overflow', () {
    final sizes = {
      '360x800': const Size(360, 800),
      '800x1100': const Size(800, 1100),
      '1500x900': const Size(1500, 900),
    };
    for (final brightness in Brightness.values) {
      for (final e in sizes.entries) {
        for (final scale in [1.0, 2.0]) {
          uiTest('${e.key} text x$scale ${brightness.name}', (tester) async {
            await pump(
              tester,
              size: e.value,
              textScale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull, reason: 'People screen');
            await openFor(tester, 'Carol Rakoto');
            expect(tester.takeException(), isNull, reason: 'choose step');
            await tester.ensureVisible(find.text('Create link'));
            await tester.tap(find.text('Create link'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'result step');
            // Everything can be reached by scrolling the dialog.
            await tester.ensureVisible(find.text('Done'));
            await tester.ensureVisible(find.text('Copy link'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // The QR code keeps its size and is not squeezed.
            final qr = tester.getSize(find.byType(QrView));
            expect(qr.width, qr.height);
            expect(qr.width, greaterThanOrEqualTo(180));
          });
        }
      }
    }

    uiTest('add a person at 360x800 and text x2', (tester) async {
      await pump(tester, size: const Size(360, 800), textScale: 2);
      await reveal(tester, find.text('Add a person'));
      await tapText(tester, 'Add a person');
      await typeKey(tester, 'person-name', 'Rosa Rakoto');
      await tapText(tester, 'Add person');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('generated-address')), findsOneWidget);
    });
  });

  group('sign-in screen', () {
    Future<void> pumpSignIn(
      WidgetTester tester, {
      double scale = 1,
      Size size = const Size(1000, 800),
    }) async {
      SharedPreferences.setMockInitialValues({});
      final cat = catalogWithPeople();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authServiceProvider.overrideWithValue(DemoAuth(cat))],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const SignInScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    uiTest('one line tells where to get a link', (tester) async {
      await pumpSignIn(tester);
      expect(
        find.text('No email address? Ask your manager for a sign-in link.'),
        findsOneWidget,
      );
      expect(find.text('Send me a link'), findsOneWidget);
      // Under the button, not above the form.
      expect(
        tester.getTopLeft(find.textContaining('No email address?')).dy,
        greaterThan(tester.getBottomLeft(find.text('Send me a link')).dy),
      );
    });

    uiTest('fits at 360x800 and text x2', (tester) async {
      await pumpSignIn(tester, scale: 2, size: const Size(360, 800));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('No email address?'), findsOneWidget);
    });
  });
}
