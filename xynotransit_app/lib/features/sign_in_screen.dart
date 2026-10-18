import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/theme/tokens.dart';
import '../core/widgets.dart';
import '../data/repository.dart';

/// Email magic link sign-in.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter your work email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signInWithEmail(email);
      if (mounted) setState(() => _sent = true);
    } on RepositoryException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Could not send the link. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: XCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Logistics Report Builder',
                    style: bodyStyle(
                      context,
                      size: 24,
                      weight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your work email. We send you a link that signs you in.',
                    style: bodyStyle(context, color: t.muted),
                  ),
                  const SizedBox(height: 16),
                  if (_sent)
                    Semantics(
                      liveRegion: true,
                      child: SoftBanner(
                        child: Text(
                          'Link sent to ${_email.text.trim()}. Open it on this device.',
                          style: bodyStyle(context, size: 15, height: 1.4),
                        ),
                      ),
                    )
                  else ...[
                    Labeled(
                      label: 'Work email',
                      child: TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: xInput(context),
                        style: bodyStyle(context),
                        onSubmitted: (_) => unawaited(_submit()),
                      ),
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
                            color: t.bad,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    PrimaryButton(
                      label: _busy ? 'Sending…' : 'Send me a link',
                      onPressed: _busy ? null : () => unawaited(_submit()),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
