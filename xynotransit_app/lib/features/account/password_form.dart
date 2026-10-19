import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/password_rules.dart';
import 'password_widgets.dart';

const linkRecoveryNote =
    'You signed in with a link, so you can choose a new password without the '
    'old one.';

/// Which of the three password moments this is.
enum PasswordMode {
  /// A link sign-in, no password yet. Optional, can be skipped.
  first,

  /// Has a password, wants another. Needs the current one.
  change,

  /// A manager gave a temporary password. Nothing else works until this is done.
  forced,
}

PasswordMode passwordModeOf(AppUser? u) {
  if (u == null) return PasswordMode.first;
  if (u.mustChangePassword) return PasswordMode.forced;
  return u.hasPassword ? PasswordMode.change : PasswordMode.first;
}

/// New password twice (and the current one when there is one), live hints and
/// a strength meter. Saves through [AuthService.changePassword], which swaps
/// in the fresh session.
class PasswordForm extends ConsumerStatefulWidget {
  const PasswordForm({
    super.key,
    required this.mode,
    required this.onDone,
    this.secondaryLabel,
    this.onSecondary,
  });

  final PasswordMode mode;

  /// Called after the password is saved.
  final VoidCallback onDone;

  /// "Skip for now" or "Cancel".
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  ConsumerState<PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends ConsumerState<PasswordForm> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _busy = false;
  String? _error;

  /// The server wanted the current password after all (the link session
  /// grew too old while this screen was open).
  bool _askCurrent = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  bool get _linkRecovery =>
      widget.mode != PasswordMode.first &&
      !_askCurrent &&
      (ref.read(userProvider).value?.recentLinkSession ?? false);

  bool get _needsCurrent => widget.mode != PasswordMode.first && !_linkRecovery;

  Future<void> _save() async {
    final user = ref.read(authServiceProvider).currentUser;
    final next = _new.text;
    String? problem;
    if (_needsCurrent && _current.text.isEmpty) {
      problem = widget.mode == PasswordMode.forced
          ? 'Enter the temporary password.'
          : PasswordRules.currentRequired;
    } else {
      problem =
          PasswordRules.check(
            next,
            username: user?.username,
            fullName: user?.label,
          ) ??
          (next == _again.text ? null : PasswordRules.mismatch);
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .changePassword(
            currentPassword: _needsCurrent ? _current.text : null,
            newPassword: next,
          );
      TextInput.finishAutofillContext();
      if (!mounted) return;
      widget.onDone();
    } on RepositoryException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          if (_linkRecovery && e.message == PasswordRules.currentRequired) {
            _askCurrent = true;
          }
        });
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Could not save the password. Check your connection and try '
              'again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final user = ref.watch(userProvider).value;
    final forced = widget.mode == PasswordMode.forced;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_linkRecovery) ...[
            Text(
              linkRecoveryNote,
              key: const Key('link-recovery-note'),
              style: bodyStyle(context, size: 15, height: 1.4),
            ),
            const SizedBox(height: 14),
          ],
          if (_needsCurrent) ...[
            PasswordField(
              key: const Key('current-password'),
              controller: _current,
              label: forced ? 'Temporary password' : 'Current password',
              autofillHints: const [AutofillHints.password],
              autofocus: true,
            ),
            const SizedBox(height: 14),
          ],
          PasswordField(
            key: const Key('new-password'),
            controller: _new,
            label: 'New password',
            autofillHints: const [AutofillHints.newPassword],
            autofocus: !_needsCurrent,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          StrengthMeter(password: _new.text),
          const SizedBox(height: 10),
          PolicyHints(
            password: _new.text,
            username: user?.username,
            fullName: user?.label,
          ),
          const SizedBox(height: 10),
          PasswordField(
            key: const Key('repeat-password'),
            controller: _again,
            label: 'Type the new password again',
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: _busy ? null : () => unawaited(_save()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const Key('password-error'),
                style: bodyStyle(context, size: 15, color: t.bad, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrimaryButton(
                label: _busy ? 'Saving…' : 'Save password',
                onPressed: _busy ? null : () => unawaited(_save()),
              ),
              if (widget.secondaryLabel != null)
                GhostButton(
                  label: widget.secondaryLabel!,
                  onPressed: _busy ? null : widget.onSecondary,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
