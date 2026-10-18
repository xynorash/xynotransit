import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    return Semantics(
      label: semanticLabel,
      button: true,
      excludeSemantics: semanticLabel != null,
      child: FilledButton(
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
      ),
    );
  }
}

class TextLinkButton extends StatelessWidget {
  const TextLinkButton({
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
      button: true,
      excludeSemantics: semanticLabel != null,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          foregroundColor: t.accent,
          textStyle: TextStyle(
            fontFamily: XynoTokens.sans,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        child: Text(label),
      ),
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
    hintStyle: bodyStyle(context, color: t.muted.withValues(alpha: 0.7)),
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
  const Labeled({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

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
        Semantics(label: label, container: true, child: child),
      ],
    );
  }
}

/// Whole-number input that keeps its text in sync with an outside value.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final int? value;
  final ValueChanged<int?> onChanged;
  final String? semanticLabel;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _c = TextEditingController(
    text: widget.value?.toString() ?? '',
  );

  @override
  void didUpdateWidget(NumberField old) {
    super.didUpdateWidget(old);
    if (int.tryParse(_c.text) != widget.value) {
      _c.text = widget.value?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      textAlign: TextAlign.center,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(9),
      ],
      style: monoStyle(
        context,
        size: 22,
        weight: FontWeight.w500,
        color: context.tokens.ink,
      ),
      decoration: xInput(context, hint: '0').copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      onChanged: (s) => widget.onChanged(int.tryParse(s)),
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
