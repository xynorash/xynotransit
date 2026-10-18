import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../core/theme/tokens.dart';
import '../core/widgets.dart';
import '../data/repository.dart';

enum _Phase { checking, signedIn, expired, offline }

/// Opened from the emailed link: /auth/verify?token=... Trades the one time
/// token for a session, then goes home.
class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key, required this.token});

  final String? token;

  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  _Phase _phase = _Phase.checking;
  String _message = '';

  static const _expired =
      'This link has expired or was already used. Ask for a new one.';

  @override
  void initState() {
    super.initState();
    unawaited(_exchange());
  }

  Future<void> _exchange() async {
    final token = widget.token;
    final auth = ref.read(authServiceProvider);
    final link = auth is LinkSignIn ? auth as LinkSignIn : null;
    if (token == null || token.isEmpty || link == null) {
      setState(() {
        _phase = _Phase.expired;
        _message = _expired;
      });
      return;
    }
    setState(() => _phase = _Phase.checking);
    try {
      await link.exchangeToken(token);
      if (!mounted) return;
      ref
        ..invalidate(catalogProvider)
        ..invalidate(periodProvider)
        ..invalidate(reportsProvider)
        ..invalidate(deckProvider);
      setState(() => _phase = _Phase.signedIn);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) context.go('/');
    } on NetworkException {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.offline;
        _message = 'Could not reach the server. Check your connection.';
      });
    } on RepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.expired;
        _message = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (title, body) = switch (_phase) {
      _Phase.checking => ('Checking your link', 'One moment.'),
      _Phase.signedIn => ('You are signed in', 'Taking you to the reports.'),
      _Phase.expired => ('This link does not work', _message),
      _Phase.offline => ('No connection', _message),
    };
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
                    title,
                    style: bodyStyle(
                      context,
                      size: 24,
                      weight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      body,
                      style: bodyStyle(context, color: t.muted),
                    ),
                  ),
                  if (_phase == _Phase.checking) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (_phase == _Phase.expired) ...[
                    const SizedBox(height: 16),
                    PrimaryButton(
                      label: 'Back to sign in',
                      onPressed: () => context.go('/signin'),
                    ),
                  ],
                  if (_phase == _Phase.offline) ...[
                    const SizedBox(height: 16),
                    PrimaryButton(
                      label: 'Try again',
                      onPressed: () => unawaited(_exchange()),
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
