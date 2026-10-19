import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../shell/top_bar.dart';
import 'password_form.dart';

/// /account/password. Three faces of one screen:
/// - after a link sign-in without a password: "Choose a password", can be skipped;
/// - with a password: "Change password", can be cancelled;
/// - after a manager's reset: "Choose a new password", blocks everything else.
class PasswordScreen extends ConsumerStatefulWidget {
  const PasswordScreen({super.key});

  @override
  ConsumerState<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends ConsumerState<PasswordScreen> {
  bool _saved = false;

  void _home() => context.go('/');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final user = ref.watch(userProvider).value;
    // The mode is read once saved too: after a save the user has a password.
    final mode = passwordModeOf(user);
    final forced = mode == PasswordMode.forced;
    final (title, intro) = _saved
        ? ('Password saved', 'You are still signed in on this device.')
        : switch (mode) {
            PasswordMode.forced => (
              'Choose a new password',
              'A manager made a temporary password for you. Choose your own '
                  'now. You need it the next time you sign in.',
            ),
            PasswordMode.first => (
              'Choose a password',
              'Then you can sign in with your username and password. Links '
                  'keep working too.',
            ),
            PasswordMode.change => (
              'Change password',
              'Other devices where you are signed in will be signed out.',
            ),
          };
    return Scaffold(
      appBar: forced ? null : const TopBar(screen: Screen.employee),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: XCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: bodyStyle(
                          context,
                          size: 24,
                          weight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      intro,
                      style: bodyStyle(context, color: t.muted, height: 1.45),
                    ),
                    if (user?.username != null && !_saved) ...[
                      const SizedBox(height: 10),
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'Your username is '),
                            TextSpan(
                              text: user!.username,
                              style: monoStyle(
                                context,
                                size: 15,
                                weight: FontWeight.w500,
                              ),
                            ),
                            const TextSpan(text: '.'),
                          ],
                        ),
                        style: bodyStyle(context, size: 15, height: 1.4),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_saved)
                      PrimaryButton(label: 'Continue', onPressed: _home)
                    else
                      PasswordForm(
                        mode: mode,
                        onDone: () {
                          if (forced || mode == PasswordMode.first) {
                            _home();
                          } else {
                            setState(() => _saved = true);
                          }
                        },
                        secondaryLabel: switch (mode) {
                          PasswordMode.first => 'Skip for now',
                          PasswordMode.change => 'Cancel',
                          PasswordMode.forced => null,
                        },
                        onSecondary: _home,
                      ),
                    if (forced) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextLinkButton(
                          label: 'Sign out',
                          flush: true,
                          onPressed: () => unawaited(
                            ref.read(authServiceProvider).signOut(),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
