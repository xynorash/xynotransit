import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/theme.dart';
import '../core/theme/tokens.dart';
import '../features/gallery_screen.dart';
import '../features/employee/employee_screen.dart';
import '../features/deck_text/deck_text_screen.dart';
import '../features/manager/people_page.dart';
import '../features/manager/reports_screen.dart';
import '../features/summary/summary_screen.dart';
import '../features/sign_in_screen.dart';
import '../features/verify_screen.dart';
import 'providers.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authServiceProvider);
  return GoRouter(
    routes: [
      // '/' only decides where a person belongs.
      GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(path: '/report', builder: (_, _) => const EmployeeScreen()),
      GoRoute(path: '/manager', builder: (_, _) => const OverviewScreen()),
      GoRoute(
        path: '/manager/reports',
        builder: (_, _) => const ReportsScreen(),
      ),
      GoRoute(path: '/manager/deck', builder: (_, _) => const DeckTextScreen()),
      GoRoute(path: '/manager/people', builder: (_, _) => const PeoplePage()),
      GoRoute(path: '/gallery', builder: (_, _) => const GalleryScreen()),
      GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
      GoRoute(
        path: '/auth/verify',
        builder: (_, state) =>
            VerifyScreen(token: state.uri.queryParameters['token']),
      ),
    ],
    refreshListenable: _StreamListenable(auth.userChanges),
    redirect: (context, state) {
      final here = state.matchedLocation;
      final user = auth.currentUser;
      if (auth.needsSignIn) {
        // The emailed link must open while signed out.
        if (here == '/auth/verify') return null;
        if (user == null) return here == '/signin' ? null : '/signin';
      }
      final home = user?.isController ?? false ? '/manager' : '/report';
      if (here == '/' || here == '/signin') return home;
      // Employees never see any manager page.
      if ((here == '/manager' || here.startsWith('/manager/')) &&
          !(user?.isController ?? false)) {
        return '/report';
      }
      return null;
    },
  );
});

class _StreamListenable extends ChangeNotifier {
  _StreamListenable(Stream<Object?> s) {
    _sub = s.listen((_) => notifyListeners());
  }

  late final StreamSubscription<Object?> _sub;

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

class XynotransitApp extends ConsumerWidget {
  const XynotransitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Xynotransit Logistics Report Builder',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => DemoNoticeShell(child: child),
    );
  }
}

/// A thin, dismissible bar on the demo build: says that the data is made up
/// and stays in this browser tab.
class DemoNoticeShell extends ConsumerWidget {
  const DemoNoticeShell({super.key, required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = child ?? const SizedBox.shrink();
    final show =
        ref.watch(demoNoticeAvailableProvider) &&
        !ref.watch(demoNoticeDismissedProvider);
    if (!show) return page;
    final t = context.tokens;
    return Column(
      children: [
        Expanded(child: page),
        Material(
          color: t.soft,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Demo: the people and reports here are made up and '
                        'stay in this browser tab.',
                        style: TextStyle(color: t.ink, fontSize: 13),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref
                        .read(demoNoticeDismissedProvider.notifier)
                        .dismiss(),
                    child: Text('Close', style: TextStyle(color: t.accent)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
