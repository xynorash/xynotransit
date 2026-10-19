import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import 'admin_providers.dart';

/// Why a switched off person has no password to reset.
const resetPasswordOffReason =
    'Switched off. Turn this person on in Edit person to reset the password.';

/// The sentence shown with the temporary password.
const tempPasswordNote =
    'Tell them to sign in with this and choose their own password. '
    'It is shown only once.';

Future<void> showResetPasswordDialog(BuildContext context, Person person) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ResetPasswordDialog(person: person),
      ),
    ),
  );
}

/// Explains, asks to confirm, then shows the temporary password once.
class ResetPasswordDialog extends ConsumerStatefulWidget {
  const ResetPasswordDialog({super.key, required this.person});
  final Person person;

  @override
  ConsumerState<ResetPasswordDialog> createState() =>
      _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends ConsumerState<ResetPasswordDialog> {
  TempPassword? _temp;
  bool _busy = false;
  bool _copied = false;
  String? _error;

  Future<void> _make() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final temp = await ref
          .read(repositoryProvider)
          .resetPassword(widget.person.id);
      if (mounted) {
        setState(() {
          _temp = temp;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = adminErrorText(e);
        });
      }
    }
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _copied = false;
          _error = 'Could not copy. Select the password and copy it by hand.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = widget.person;
    final temp = _temp;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Reset password for ${p.fullName}',
                    style: bodyStyle(
                      context,
                      size: 20,
                      weight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (temp == null) ...[
            Text(
              p.hasPassword
                  ? 'This makes a temporary password. The old password stops '
                        'working and ${p.fullName} is signed out everywhere.'
                  : 'This makes a temporary password so ${p.fullName} can '
                        'sign in with a username.',
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.45),
            ),
            const SizedBox(height: 6),
            Text(
              'They must choose their own password the first time they use '
              'it. Making another temporary password replaces this one.',
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.45),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: bodyStyle(
                    context,
                    size: 15,
                    weight: FontWeight.w500,
                    color: t.bad,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                PrimaryButton(
                  label: _busy ? 'Making…' : 'Make a temporary password',
                  onPressed: _busy ? null : () => unawaited(_make()),
                ),
                GhostButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ] else ...[
            Labeled(
              label: 'Username',
              child: SelectableText(
                temp.username,
                key: const Key('temp-username'),
                style: monoStyle(context, size: 16),
              ),
            ),
            const SizedBox(height: 12),
            Labeled(
              label: 'Temporary password',
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: t.soft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  temp.password,
                  key: const Key('temp-password'),
                  style: monoStyle(context, size: 22, weight: FontWeight.w500),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PrimaryButton(
                  label: 'Copy password',
                  onPressed: () => unawaited(_copy(temp.password)),
                ),
                if (_copied)
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check, size: 18, color: t.ok),
                        const SizedBox(width: 4),
                        Text(
                          'Copied',
                          style: bodyStyle(
                            context,
                            size: 15,
                            weight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: bodyStyle(context, size: 15, color: t.bad, height: 1.4),
              ),
            ],
            const SizedBox(height: 14),
            SoftBanner(
              child: Text(
                tempPasswordNote,
                key: const Key('temp-password-note'),
                style: bodyStyle(context, size: 15, height: 1.45),
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: GhostButton(
                label: 'Done',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Asks, then takes the password away. Returns true when it was removed.
Future<bool> confirmRemovePassword(
  BuildContext context,
  WidgetRef ref,
  Person person,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove the password of ${person.fullName}?'),
      content: Text(
        '${person.fullName} will sign in with links only, and is signed out '
        'everywhere. You can make a new password later.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep password'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove password'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(repositoryProvider).removePassword(person.id);
    messenger?.showSnackBar(
      SnackBar(content: Text('Password of ${person.fullName} removed.')),
    );
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(adminErrorText(e))));
    return false;
  }
}
