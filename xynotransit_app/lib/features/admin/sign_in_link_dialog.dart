import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import 'admin_providers.dart';
import 'qr_view.dart';

/// Why a switched off person has no sign-in link.
const signInLinkOffReason =
    'Switched off. Turn this person on in Edit person to make a link.';

/// The words to paste into a chat next to the link.
String signInMessage(String url) =>
    'Open this link to sign in to Xynotransit: $url';

Future<void> showSignInLinkDialog(BuildContext context, Person person) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SignInLinkDialog(person: person),
      ),
    ),
  );
}

/// How long a new link works.
enum LinkValidity {
  oneHour('1 hour', 1),
  oneDay('24 hours', 24),
  sevenDays('7 days', 168);

  const LinkValidity(this.label, this.hours);
  final String label;
  final int hours;
}

/// A manager makes a one time sign-in link for [person], and copies it, shows
/// it as a QR code or reads it out.
class SignInLinkDialog extends ConsumerStatefulWidget {
  const SignInLinkDialog({super.key, required this.person});
  final Person person;

  @override
  ConsumerState<SignInLinkDialog> createState() => _SignInLinkDialogState();
}

enum _Copied { none, link, message }

class _SignInLinkDialogState extends ConsumerState<SignInLinkDialog> {
  LinkValidity _validity = LinkValidity.oneDay;
  SignInLink? _link;
  bool _busy = false;
  String? _error;
  _Copied _copied = _Copied.none;
  final _field = FocusNode();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final link = await ref
          .read(repositoryProvider)
          .createSignInLink(widget.person.id, hours: _validity.hours);
      if (!mounted) return;
      setState(() {
        _link = link;
        _busy = false;
        _copied = _Copied.none;
      });
      // Move the reader to the new link.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _field.requestFocus();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = adminErrorText(e);
      });
    }
  }

  Future<void> _copy(String text, _Copied what) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) setState(() => _copied = what);
    } catch (_) {
      if (mounted) {
        setState(() {
          _copied = _Copied.none;
          _error = 'Could not copy. Select the link and copy it by hand.';
        });
      }
    }
  }

  void _again() {
    setState(() {
      _link = null;
      _copied = _Copied.none;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = widget.person.fullName;
    final link = _link;
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
                    'Sign-in link for $name',
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
          Text(
            'A link that signs $name in without an email. It works once. '
            'Send it to them in a chat, or let them scan the code.',
            style: bodyStyle(context, size: 15, color: t.muted, height: 1.45),
          ),
          const SizedBox(height: 16),
          if (link == null) ..._choose(context) else ..._result(context, link),
        ],
      ),
    );
  }

  List<Widget> _choose(BuildContext context) {
    final t = context.tokens;
    return [
      Semantics(
        header: true,
        child: Text(
          'How long should the link work?',
          style: bodyStyle(context, size: 15, weight: FontWeight.w500),
        ),
      ),
      const SizedBox(height: 8),
      Semantics(
        container: true,
        label: 'How long the link works',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in LinkValidity.values)
              ChoiceChip(
                key: Key('validity-${v.hours}'),
                label: Text(v.label),
                selected: _validity == v,
                autofocus: v == LinkValidity.oneDay,
                showCheckmark: true,
                labelStyle: bodyStyle(context, size: 15),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.standard,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                onSelected: _busy ? null : (_) => setState(() => _validity = v),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PrimaryButton(
            label: _busy ? 'Creating…' : 'Create link',
            onPressed: _busy ? null : () => unawaited(_create()),
          ),
          if (_error != null) _message(context, _error!),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        'Making another link later does not turn off the ones you made '
        'before. Each link works until it is used or it runs out.',
        style: bodyStyle(context, size: 14, color: t.muted, height: 1.4),
      ),
    ];
  }

  Widget _message(BuildContext context, String m) => Semantics(
    liveRegion: true,
    child: Text(
      m,
      style: bodyStyle(
        context,
        size: 15,
        weight: FontWeight.w500,
        color: context.tokens.bad,
        height: 1.4,
      ),
    ),
  );

  List<Widget> _result(BuildContext context, SignInLink link) {
    final t = context.tokens;
    final name = widget.person.fullName;
    final message = signInMessage(link.url);
    return [
      LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 540;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Labeled(
                label: 'Sign-in link',
                child: TextFormField(
                  key: const Key('sign-in-link-url'),
                  focusNode: _field,
                  initialValue: link.url,
                  readOnly: true,
                  minLines: 1,
                  maxLines: 5,
                  style: monoStyle(context, size: 13),
                  decoration: xInput(context),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PrimaryButton(
                    label: 'Copy link',
                    onPressed: () => unawaited(_copy(link.url, _Copied.link)),
                  ),
                  if (_copied == _Copied.link) _copiedNote(context),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                _message(context, _error!),
              ],
              const SizedBox(height: 14),
              Text(
                'Works until ${longDateTime(link.expiresAt)}, or until it is '
                'used.',
                key: const Key('sign-in-link-expiry'),
                style: bodyStyle(
                  context,
                  size: 15,
                  weight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ],
          );
          final qr = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: t.line),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: QrView(data: link.url, size: 200),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 200,
                child: Text(
                  'Let them scan this code with their phone camera.',
                  textAlign: TextAlign.center,
                  style: bodyStyle(context, size: 14, color: t.muted),
                ),
              ),
            ],
          );
          return wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 20),
                    qr,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    left,
                    const SizedBox(height: 18),
                    Center(child: qr),
                  ],
                );
        },
      ),
      const SizedBox(height: 16),
      Semantics(
        header: true,
        child: Text(
          'Message to paste',
          style: bodyStyle(context, size: 15, weight: FontWeight.w500),
        ),
      ),
      const SizedBox(height: 6),
      SelectableText(
        message,
        key: const Key('sign-in-link-message'),
        style: bodyStyle(context, size: 14, height: 1.45),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GhostButton(
            label: 'Copy message',
            onPressed: () => unawaited(_copy(message, _Copied.message)),
          ),
          if (_copied == _Copied.message) _copiedNote(context),
        ],
      ),
      const SizedBox(height: 16),
      SoftBanner(
        child: Text(
          'Anyone who has this link can sign in as $name until it is used or '
          'it expires. Share it privately.',
          key: const Key('sign-in-link-warning'),
          style: bodyStyle(context, size: 15, height: 1.45),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Making another link does not turn this one off.',
        style: bodyStyle(context, size: 14, color: t.muted, height: 1.4),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          GhostButton(label: 'Make another link', onPressed: _again),
          GhostButton(
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ];
  }

  Widget _copiedNote(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check, size: 18, color: context.tokens.ok),
        const SizedBox(width: 4),
        Text(
          'Copied',
          style: bodyStyle(context, size: 15, weight: FontWeight.w500),
        ),
      ],
    ),
  );
}
