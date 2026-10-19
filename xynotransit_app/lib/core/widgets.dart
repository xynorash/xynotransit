import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/numbers.dart';
import 'format.dart';
import 'theme/tokens.dart';

TextStyle monoStyle(
  BuildContext c, {
  double size = 14,
  FontWeight weight = FontWeight.w400,
  Color? color,
}) => TextStyle(
  fontFamily: XynoTokens.mono,
  fontSize: size,
  fontWeight: weight,
  color: color ?? c.tokens.muted,
  height: 1.4,
);

TextStyle bodyStyle(
  BuildContext c, {
  double size = 17,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.5,
}) => TextStyle(
  fontFamily: XynoTokens.sans,
  fontSize: size,
  fontWeight: weight,
  color: color ?? c.tokens.ink,
  height: height,
);

bool reducedMotion(BuildContext c) => MediaQuery.disableAnimationsOf(c);

/// White card with border, used for every form section.
class XCard extends StatelessWidget {
  const XCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

/// Numbered card: badge, title, optional hint, then the content.
class StepCard extends StatelessWidget {
  const StepCard({
    super.key,
    required this.step,
    required this.title,
    this.hint,
    required this.child,
  });

  final int step;
  final String title;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.ink,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$step',
                    textScaler: TextScaler.noScaling,
                    style: monoStyle(
                      context,
                      size: 13,
                      weight: FontWeight.w500,
                      color: t.bg,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: bodyStyle(
                      context,
                      size: 20,
                      weight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

ButtonStyle _base(
  BuildContext c, {
  required Color fill,
  required Color on,
  double minHeight = 46,
  double size = 17,
  double hPad = 20,
  double radius = 10,
  FontWeight weight = FontWeight.w700,
}) {
  final t = c.tokens;
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(44, minHeight)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: hPad)),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) =>
          s.contains(WidgetState.disabled) ? fill.withValues(alpha: 0.5) : fill,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? on.withValues(alpha: 0.5) : on,
    ),
    overlayColor: WidgetStatePropertyAll(on.withValues(alpha: 0.08)),
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: WidgetStateProperty.resolveWith(
      (s) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: s.contains(WidgetState.focused)
            ? BorderSide(color: t.accent, width: 3)
            : BorderSide.none,
      ),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(
        fontFamily: XynoTokens.sans,
        fontSize: size,
        fontWeight: weight,
      ),
    ),
    tapTargetSize: MaterialTapTargetSize.padded,
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.large = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FilledButton(
      onPressed: onPressed,
      style: _base(
        context,
        fill: t.accent,
        on: t.onAccent,
        minHeight: large ? 52 : 46,
        size: large ? 18 : 17,
        hPad: large ? 28 : 20,
      ),
      child: Text(label),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: semanticLabel,
      child: FilledButton(
        onPressed: onPressed,
        style: _base(context, fill: t.soft, on: t.ink, weight: FontWeight.w500),
        child: Text(label),
      ),
    );
  }
}

/// The small soft button used in table rows.
class SmallButton extends StatelessWidget {
  const SmallButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final button = FilledButton(
      onPressed: onPressed,
      style: _base(
        context,
        fill: t.soft,
        on: t.ink,
        minHeight: 34,
        size: 14,
        hPad: 14,
        radius: 8,
        weight: FontWeight.w500,
      ),
      child: Text(label),
    );
    return semanticLabel == null
        ? button
        : Semantics(
            label: semanticLabel,
            button: true,
            enabled: onPressed != null,
            excludeSemantics: true,
            child: button,
          );
  }
}

class TextLinkButton extends StatelessWidget {
  const TextLinkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.flush = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  /// No side padding, so the text lines up with the content around it.
  final bool flush;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: flush ? EdgeInsets.zero : null,
        foregroundColor: t.accent,
        textStyle: TextStyle(
          fontFamily: XynoTokens.sans,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      child: Text(label),
    );
    return semanticLabel == null
        ? button
        : Semantics(
            label: semanticLabel,
            button: true,
            excludeSemantics: true,
            child: button,
          );
  }
}

InputDecoration xInput(BuildContext context, {String? hint, String? counter}) {
  final t = context.tokens;
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: t.bg,
    hintText: hint,
    hintStyle: bodyStyle(context, color: t.muted),
    counterText: counter ?? '',
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    constraints: const BoxConstraints(minHeight: 46),
    border: border(t.line),
    enabledBorder: border(t.line),
    disabledBorder: border(t.line),
    focusedBorder: border(t.accent, 2),
  );
}

/// A label above a field, with the label spoken as the field name.
class Labeled extends StatelessWidget {
  const Labeled({
    super.key,
    required this.label,
    required this.child,
    this.mergeChild = false,
  });

  final String label;
  final Widget child;

  /// Join the label and the child into one node. For a drop-down, whose
  /// button has no name of its own.
  final bool mergeChild;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: bodyStyle(
              context,
              size: 15,
              weight: FontWeight.w500,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 6),
        mergeChild
            ? MergeSemantics(
                child: Semantics(label: label, child: child),
              )
            : Semantics(label: label, container: true, child: child),
      ],
    );
  }
}

/// Plain message when a number is over [countMax].
const numberTooLargeMessage = 'A number can be at most $countMax.';

/// Reads a pasted or typed whole number. Spaces, thin spaces and commas are
/// thousands separators and are dropped. Returns the digits, or a plain
/// message when the text is not a whole number from 0 up to [countMax].
({String? digits, String? problem}) parseWholeNumber(String raw) {
  final cleaned = raw.replaceAll(RegExp(r"[\s\u00A0\u202F,'\u2019_]"), '');
  if (cleaned.isEmpty) return (digits: '', problem: null);
  if (!RegExp(r'^\d+$').hasMatch(cleaned)) {
    final decimalOrNegative = RegExp(r'[.\-\u2212]').hasMatch(cleaned);
    return (
      digits: null,
      problem: decimalOrNegative ? 'Whole numbers only' : 'Digits only',
    );
  }
  final trimmed = cleaned.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (parseCount(trimmed) == null) {
    return (digits: null, problem: numberTooLargeMessage);
  }
  return (digits: trimmed, problem: null);
}

class _WholeNumberFormatter extends TextInputFormatter {
  _WholeNumberFormatter(this.onProblem);

  final ValueChanged<String?> onProblem;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final r = parseWholeNumber(newValue.text);
    if (r.problem != null) {
      onProblem(r.problem);
      return oldValue;
    }
    onProblem(null);
    if (r.digits == newValue.text) return newValue;
    return TextEditingValue(
      text: r.digits!,
      selection: TextSelection.collapsed(offset: r.digits!.length),
    );
  }
}

/// Whole-number input that keeps its text in sync with an outside value.
/// Accepts pasted text with spaces or thousands separators, refuses decimals,
/// minus signs and letters with a plain message, and shows thousands
/// separators while the field is not being edited.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.errorText,
    this.focusNode,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String? semanticLabel;

  /// Shown under the field, for example "Enter a number".
  final String? errorText;
  final FocusNode? focusNode;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _c = TextEditingController(
    text: _show(widget.value, false),
  );
  FocusNode? _own;
  String? _problem;

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  late final _formatter = _WholeNumberFormatter((p) {
    if (p != _problem) {
      // Called from inside the text input: show it after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _problem = p);
      });
    }
  });

  static String _show(int? v, bool focused) => v == null
      ? ''
      : focused
      ? v.toString()
      : thousands(v);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    final text = _show(
      parseCount(_c.text.replaceAll(',', '')),
      _focus.hasFocus,
    );
    if (text != _c.text) _c.text = text;
    if (!_focus.hasFocus && _problem != null) setState(() => _problem = null);
  }

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
    final typed = parseCount(_c.text.replaceAll(',', ''));
    if (typed != widget.value) {
      _c.text = _show(widget.value, _focus.hasFocus);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _own?.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final error = _problem ?? widget.errorText;
    final deco = xInput(context, hint: '0').copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      errorText: error,
      errorMaxLines: 3,
      errorStyle: bodyStyle(context, size: 13, color: t.bad, height: 1.25),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.bad),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.bad, width: 2),
      ),
    );
    final field = TextField(
      controller: _c,
      focusNode: _focus,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [_formatter],
      textInputAction: TextInputAction.next,
      style: monoStyle(
        context,
        size: 22,
        weight: FontWeight.w500,
        color: t.ink,
      ),
      decoration: deco,
      onChanged: (s) => widget.onChanged(
        s.isEmpty ? null : parseCount(s.replaceAll(',', '')),
      ),
    );
    final name = widget.semanticLabel;
    // The name joins the field's own node, so it is one text field to a
    // screen reader, not a wrapper holding another one.
    return name == null ? field : Semantics(label: name, child: field);
  }
}

/// "12/70" under or beside a text box. Turns warning-coloured from 90 percent
/// of the limit, and says so in words for screen readers.
class CharCounter extends StatelessWidget {
  const CharCounter({super.key, required this.length, required this.max});

  final int length;
  final int max;

  static bool isNear(int length, int max) => length * 10 >= max * 9;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final near = isNear(length, max);
    final full = length >= max;
    return Semantics(
      label: full
          ? '$length of $max characters, limit reached'
          : near
          ? '$length of $max characters, close to the limit'
          : '$length of $max characters',
      excludeSemantics: true,
      child: Text(
        '$length/$max',
        style: monoStyle(
          context,
          size: 12,
          weight: near ? FontWeight.w500 : FontWeight.w400,
          color: near ? t.warn : t.muted,
        ),
      ),
    );
  }
}

/// Dashed rounded box for empty states.
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return CustomPaint(
      painter: _DashedPainter(t.line),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Center(child: child),
      ),
    );
  }
}

class _DashedPainter extends CustomPainter {
  _DashedPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      );
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) => old.color != color;
}

/// Soft banner (radius 10) used for notices and confirmations.
class SoftBanner extends StatelessWidget {
  const SoftBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.tokens.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}
