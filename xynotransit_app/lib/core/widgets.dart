import 'package:flutter/material.dart';

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

/// Plain message when the text is not a whole number.
const wholeNumbersOnlyMessage =
    'Whole numbers only: no dots, commas or letters.';

/// Reads a pasted or typed whole number: digits, with spaces, thin spaces or
/// no-break spaces as thousands separators (dropped). Returns the digits, or a
/// plain message when the text is not a whole number from 0 up to [countMax].
/// Dots, commas, signs and letters are never guessed at: the text is refused.
({String? digits, String? problem}) parseWholeNumber(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[\s   ]'), '');
  if (cleaned.isEmpty) return (digits: '', problem: null);
  if (!RegExp(r'^[0-9]+$').hasMatch(cleaned)) {
    return (digits: null, problem: wholeNumbersOnlyMessage);
  }
  final trimmed = cleaned.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
  if (parseCount(trimmed) == null) {
    return (digits: null, problem: numberTooLargeMessage);
  }
  return (digits: trimmed, problem: null);
}

/// Pixels the field's border and decoration take besides its padding.
const _chrome = 10.0;

/// The widest number a count can show with separators.
const _widestNumber = '0,000,000,000';

/// Whole-number input that keeps its text in sync with an outside value.
///
/// The text stays exactly as typed: nothing is dropped. When it is not a whole
/// number (see [parseWholeNumber]) the field is invalid: the value counts as
/// missing (null), a plain message stays under the field with a red outline.
/// Separators show only when a valid value is left, and the text size shrinks
/// when needed so the largest number (13 characters) always fits.
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

  /// The text last written with separators; anything else is as typed.
  String? _display = '';

  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  String _show(int? v, bool focused) {
    if (v == null) return _display = '';
    final text = focused ? v.toString() : thousands(v);
    _display = focused ? null : text;
    return text;
  }

  /// The value the text stands for: null when empty or not a whole number.
  int? _valueOf(String text) {
    // Separators the field wrote itself are not typed text.
    final plain = text == _display ? text.replaceAll(',', '') : text;
    final r = parseWholeNumber(plain);
    if (r.problem != null || r.digits!.isEmpty) return null;
    return int.parse(r.digits!);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    // Only text that is a valid number is rewritten; anything else stays as typed.
    final v = _valueOf(_c.text);
    if (v == null) return;
    final text = _show(v, _focus.hasFocus);
    if (text != _c.text) _c.text = text;
  }

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
    if (_valueOf(_c.text) != widget.value) {
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

  void _changed(String s) {
    setState(() {});
    widget.onChanged(_valueOf(s));
  }

  /// Font size at which [_widestNumber] fits [inner] pixels, at most [size].
  double _fit(BuildContext context, double inner, double size) {
    final scaler = MediaQuery.textScalerOf(context);
    double width(double s) {
      final p = TextPainter(
        text: TextSpan(
          text: _widestNumber,
          style: monoStyle(
            context,
            size: s,
            weight: FontWeight.w500,
          ).copyWith(letterSpacing: 0),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    final w = width(size);
    if (w <= inner || inner <= 0) return size;
    return (size * inner / w * 0.96).clamp(9.0, size);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final problem = parseWholeNumber(
      _c.text == _display ? _c.text.replaceAll(',', '') : _c.text,
    ).problem;
    final error = problem ?? widget.errorText;
    const pad = 4.0;
    final deco = xInput(context, hint: '0').copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: pad, vertical: 8),
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
    final field = LayoutBuilder(
      builder: (context, box) => TextField(
        controller: _c,
        focusNode: _focus,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        style: monoStyle(
          context,
          size: _fit(context, box.maxWidth - 2 * pad - _chrome, 22),
          weight: FontWeight.w500,
          color: t.ink,
        ).copyWith(letterSpacing: 0),
        decoration: deco,
        onChanged: _changed,
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
