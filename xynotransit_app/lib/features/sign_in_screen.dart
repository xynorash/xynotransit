import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/theme/tokens.dart';
import '../core/widgets.dart';
import '../data/repository.dart';
import 'account/password_widgets.dart';

/// Sign in with a username and password. A link by email is the way to get
/// started and to recover.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _email = TextEditingController();
  bool _signingIn = false;
  String? _loginError;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final name = _username.text.trim();
    if (name.isEmpty || _password.text.isEmpty) {
      setState(
        () => _loginError = name.isEmpty
            ? 'Enter your username.'
            : 'Enter your password.',
      );
      return;
    }
    setState(() {
      _signingIn = true;
      _loginError = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .signInWithPassword(name, _password.text);
      ref.read(signInNoticeProvider.notifier).set(null);
      // Tell the browser the sign-in worked so it offers to save the password.
      TextInput.finishAutofillContext();
    } on RepositoryException catch (e) {
      if (mounted) setState(() => _loginError = e.message);
    } on Object {
      if (mounted) {
        setState(
          () => _loginError =
              'Could not sign in. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
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
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
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
                        'Logistics Report Builder',
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
                      'Sign in with your username and password.',
                      style: bodyStyle(context, color: t.muted),
                    ),
                    if (ref.watch(signInNoticeProvider) case final notice?) ...[
                      const SizedBox(height: 12),
                      SoftBanner(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            notice,
                            key: const Key('signin-notice'),
                            style: bodyStyle(context, size: 15, height: 1.45),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    AutofillGroup(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Labeled(
                            label: 'Username',
                            child: TextField(
                              key: const Key('signin-username'),
                              controller: _username,
                              keyboardType: TextInputType.text,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.username],
                              autocorrect: false,
                              enableSuggestions: false,
                              decoration: xInput(context),
                              style: bodyStyle(context),
                            ),
                          ),
                          const SizedBox(height: 12),
                          PasswordField(
                            key: const Key('signin-password'),
                            controller: _password,
                            label: 'Password',
                            autofillHints: const [AutofillHints.password],
                            textInputAction: TextInputAction.done,
                            onSubmitted: _signingIn
                                ? null
                                : () => unawaited(_signIn()),
                          ),
                        ],
                      ),
                    ),
                    if (_loginError != null) ...[
                      const SizedBox(height: 10),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _loginError!,
                          key: const Key('signin-error'),
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
                      label: _signingIn ? 'Signing in…' : 'Sign in',
                      onPressed: _signingIn ? null : () => unawaited(_signIn()),
                    ),
                    const SizedBox(height: 24),
                    _linkSection(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The calm second way in: a link by email.
  Widget _linkSection(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Sign in with a link instead',
              style: bodyStyle(context, size: 17, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Enter your work email. We send you a link that signs you in.',
            style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (_sent)
            Semantics(
              liveRegion: true,
              child: Text(
                'Link sent to ${_email.text.trim()}. Open it on this device.',
                style: bodyStyle(context, size: 15, height: 1.4),
              ),
            )
          else ...[
            Labeled(
              label: 'Work email',
              child: TextField(
                key: const Key('signin-email'),
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
            const SizedBox(height: 12),
            GhostButton(
              label: _busy ? 'Sending…' : 'Send me a link',
              onPressed: _busy ? null : () => unawaited(_submit()),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'No email address? Ask your manager for a sign-in link.',
            style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
          ),
          const SizedBox(height: 4),
          Text(
            'Forgot your password? Send yourself a link by email above, then '
            'choose a new password. No email? Ask your manager to reset it.',
            style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
          ),
        ],
      ),
    );
  }
}
