import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/password_rules.dart';
import '../../domain/text_rules.dart';

/// A password box with a show/hide button. Spaces and everything else are
/// kept exactly as typed.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.autofillHints = const [AutofillHints.password],
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final Iterable<String> autofillHints;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    return Labeled(
      label: widget.label,
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        obscureText: !_shown,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        autofillHints: widget.autofillHints,
        textInputAction: widget.textInputAction,
        style: bodyStyle(context),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted == null
            ? null
            : (_) => widget.onSubmitted!(),
        decoration: xInput(context, hint: widget.hint).copyWith(
          suffixIcon: IconButton(
            tooltip: _shown ? 'Hide password' : 'Show password',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: () => setState(() => _shown = !_shown),
            icon: Icon(
              _shown
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

/// Four bars and a word. It only looks at length and at whether the password
/// is a common one, and says so.
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = PasswordRules.strength(password);
    final (bars, color) = switch (s) {
      PasswordStrength.empty => (0, t.line),
      PasswordStrength.tooShort => (1, t.bad),
      PasswordStrength.weak => (1, t.bad),
      PasswordStrength.fair => (2, t.warn),
      PasswordStrength.good => (3, t.ok),
      PasswordStrength.strong => (4, t.ok),
    };
    final words = PasswordRules.strengthWords(s);
    return Semantics(
      container: true,
      liveRegion: true,
      label: words.isEmpty
          ? 'Password strength: not started'
          : 'Password strength: $words',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              Expanded(
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < bars ? color : t.line,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            const SizedBox(width: 4),
            SizedBox(
              width: 130,
              child: Text(
                words.isEmpty ? 'Strength' : words,
                key: const Key('strength-words'),
                style: bodyStyle(
                  context,
                  size: 14,
                  weight: FontWeight.w500,
                  color: words.isEmpty ? t.muted : t.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a good password needs, checked as the person types. A line gets a
/// tick when it holds. Nothing is shown in red before they type.
class PolicyHints extends StatelessWidget {
  const PolicyHints({
    super.key,
    required this.password,
    this.username,
    this.fullName,
    this.email,
  });

  final String password;
  final String? username;
  final String? fullName;
  final String? email;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final typed = password.isNotEmpty;
    final n = charCount(password);
    final problem = PasswordRules.check(
      password,
      username: username,
      fullName: fullName,
      email: email,
    );
    final lengthOk =
        n >= PasswordRules.minLength && n <= PasswordRules.maxLength;
    final guessOk =
        lengthOk &&
        problem != PasswordRules.tooCommon &&
        problem != PasswordRules.repeated &&
        problem != PasswordRules.simpleRun;
    final youOk = lengthOk && problem != PasswordRules.looksLikeYou;
    Widget line(String text, bool ok) {
      final done = typed && ok;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(
                done ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: done ? t.ok : t.muted,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                label: '$text, ${done ? 'done' : 'not yet'}',
                excludeSemantics: true,
                child: Text(
                  text,
                  style: bodyStyle(
                    context,
                    size: 14,
                    color: done ? t.ink : t.muted,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        line('10 to 128 characters. Spaces are fine.', lengthOk),
        line('Not a common password or a simple run like 1234567890.', guessOk),
        line('Not your username, email or name.', youOk),
      ],
    );
  }
}
