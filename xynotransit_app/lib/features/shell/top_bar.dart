import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/memory_repository.dart';
import '../../data/repository.dart';

/// The sections of the app. All but [employee] are manager only.
enum Screen { employee, overview, reports, deckText, people }

/// Where each manager section lives, in menu order.
const _sections = [
  (Screen.overview, 'Overview', '/manager'),
  (Screen.reports, 'Reports', '/manager/reports'),
  (Screen.deckText, 'Deck text', '/manager/deck'),
  (Screen.people, 'People', '/manager/people'),
  (Screen.employee, 'Fill in a report', '/report'),
];

/// App bar shared by every screen. A manager gets the section navigation.
class TopBar extends ConsumerWidget implements PreferredSizeWidget {
  const TopBar({super.key, required this.screen});

  final Screen screen;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final user = ref.watch(userProvider).value;
    final brightness = Theme.of(context).brightness;
    final isManager = user?.isController ?? false;
    final compact = MediaQuery.sizeOf(context).width < (isManager ? 900 : 640);
    if (compact) {
      return _compact(context, ref, auth, user, brightness, isManager);
    }
    return AppBar(
      title: Text(
        screen == Screen.employee ? 'Xynotransit' : 'Xynotransit · Manager',
      ),
      actions: [
        if (isManager)
          for (final (s, label, path) in _sections)
            _NavLink(
              label: label,
              selected: s == screen,
              onPressed: () => context.go(path),
            ),
        if (auth is DemoAuth)
          PopupMenuButton<AppUser>(
            tooltip: 'Demo: act as someone else',
            onSelected: auth.actAs,
            itemBuilder: (_) => [
              for (final u in auth.choices)
                PopupMenuItem(value: u, child: Text(u.label)),
            ],
            child: Semantics(
              label: 'Demo: act as someone else',
              button: true,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Center(
                  child: Text(
                    'Demo: ${user?.label ?? ''}',
                    style: monoStyle(
                      context,
                      size: 13,
                      color: context.tokens.ink,
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (user != null)
          TextLinkButton(label: 'Sign out', onPressed: auth.signOut),
        IconButton(
          tooltip: brightness == Brightness.dark
              ? 'Switch to light mode'
              : 'Switch to dark mode',
          onPressed: () =>
              ref.read(themeModeProvider.notifier).toggle(brightness),
          icon: Icon(
            brightness == Brightness.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// Phones: one menu instead of a row of links, so nothing can overflow.
  AppBar _compact(
    BuildContext context,
    WidgetRef ref,
    AuthService auth,
    AppUser? user,
    Brightness brightness,
    bool isManager,
  ) {
    final dark = brightness == Brightness.dark;
    return AppBar(
      title: Text(
        screen == Screen.employee ? 'Xynotransit' : 'Xynotransit · Manager',
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        PopupMenuButton<void>(
          tooltip: 'Menu',
          icon: const Icon(Icons.menu),
          itemBuilder: (_) => [
            if (isManager)
              for (final (s, label, path) in _sections)
                PopupMenuItem(
                  onTap: () => context.go(path),
                  child: Semantics(
                    selected: s == screen,
                    child: Text(
                      label,
                      style: s == screen
                          ? const TextStyle(fontWeight: FontWeight.w700)
                          : null,
                    ),
                  ),
                ),
            if (auth is DemoAuth)
              for (final u in auth.choices)
                PopupMenuItem(
                  onTap: () => auth.actAs(u),
                  child: Text('Demo: act as ${u.label}'),
                )
            else if (user != null)
              PopupMenuItem(onTap: auth.signOut, child: const Text('Sign out')),
            PopupMenuItem(
              onTap: () =>
                  ref.read(themeModeProvider.notifier).toggle(brightness),
              child: Text(
                dark ? 'Switch to light mode' : 'Switch to dark mode',
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// One section link. The current section is bold with an underline.
class _NavLink extends StatelessWidget {
  const _NavLink({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      selected: selected,
      button: true,
      excludeSemantics: true,
      label: selected ? '$label, current section' : label,
      onTap: onPressed,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: selected ? t.ink : t.accent,
          textStyle: TextStyle(
            fontFamily: XynoTokens.sans,
            fontSize: 15,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            decoration: selected ? TextDecoration.underline : null,
            decorationThickness: 2,
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
