import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';

final _whole = NumberFormat.decimalPattern('en');
final _compact = NumberFormat.compact(locale: 'en');

/// 12,345
String fmtInt(num n) => _whole.format(n);

/// 12K, for axis labels.
String fmtCompact(num n) => _compact.format(n);

/// 63% from a 0..1 share.
String fmtPct(double share) => '${(share * 100).round()}%';

/// A white card with a title, a one line explanation and the chart.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.explain,
    required this.child,
  });

  final String title;
  final String explain;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
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
          const SizedBox(height: 4),
          Text(explain, style: bodyStyle(context, size: 14, color: t.muted)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Reads [label] aloud as the chart's text alternative and hides the drawing.
class ChartText extends StatelessWidget {
  const ChartText({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    child: ExcludeSemantics(child: child),
  );
}

/// One coloured part of a [StackedBar].
class BarPart {
  const BarPart(this.value, this.color);
  final int value;
  final Color color;
}

/// A horizontal bar made of parts. With [fullWidth] the parts fill the bar
/// (100 percent stacked); otherwise the bar is [fraction] of the width.
class StackedBar extends StatelessWidget {
  const StackedBar({
    super.key,
    required this.parts,
    this.height = 16,
    this.fraction = 1,
  });

  final List<BarPart> parts;
  final double height;

  /// Share of the available width the whole bar uses, 0..1.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = [
      for (final p in parts)
        if (p.value > 0) p,
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 200.0;
        return ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: Container(
            height: height,
            width: w,
            color: t.soft,
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: w * fraction.clamp(0, 1),
              child: Row(
                children: [
                  for (final p in shown)
                    Expanded(
                      flex: p.value,
                      child: ColoredBox(
                        color: p.color,
                        child: SizedBox(height: height),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A coloured dot and a word.
class LegendItem extends StatelessWidget {
  const LegendItem({super.key, required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: bodyStyle(context, size: 13, color: t.muted, height: 1.3),
          ),
        ),
      ],
    );
  }
}

class Legend extends StatelessWidget {
  const Legend({super.key, required this.items});

  final List<LegendItem> items;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 16, runSpacing: 6, children: items);
}

/// A label on the left, a number on the right, a bar below.
class BarRow extends StatelessWidget {
  const BarRow({
    super.key,
    required this.label,
    required this.value,
    required this.bar,
    this.footer,
  });

  final String label;
  final String value;
  final Widget bar;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
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
              const SizedBox(width: 8),
              Text(value, style: monoStyle(context, size: 13, color: t.ink)),
            ],
          ),
          const SizedBox(height: 5),
          bar,
          if (footer != null) ...[const SizedBox(height: 4), footer!],
        ],
      ),
    );
  }
}

/// A message in a card, for empty and error states.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.title,
    required this.body,
    this.action,
  });

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: bodyStyle(context, size: 20, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: bodyStyle(context, color: t.muted)),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}
