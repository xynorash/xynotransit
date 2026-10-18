import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/theme.dart';
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
    );
  }
}
