import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../domain/deck_text.dart';
import '../../domain/enums.dart';
import '../../domain/snapshot.dart';
import '../../core/theme/tokens.dart' show seriesColor;
import 'canvas.dart';
import 'fit.dart';
import 'palette.dart';
import 'slide_words.dart';

/// Slide 1 of 2: targets on the left, monthly volumes on the right.
class SlideKpi extends StatelessWidget {
  const SlideKpi(this.snapshot, {super.key, this.texts = DeckTexts.empty});

  final ReportSnapshot snapshot;
  final DeckTexts texts;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final w = SlideWords(texts);
    final fit = fitKpis([for (final t in s.targets) t.text]);
    return PersonSlideFrame(
      background: SlidePalette.paper,
      footerColor: SlidePalette.mutedOnLight,
      source: w.footer(s),
      page: '1 / 2',
      heading: SlideHeading(
        eyebrow: w.kpiEyebrow(s),
        title: w.kpiTitle(s),
        // Keep clear of the badge at the top right.
        maxWidth: slideTextWidth - 420 - 32,
        eyebrowColor: SlidePalette.blue,
        titleColor: SlidePalette.ink,
      ),
      badge: _Badge(w.kpiBadge(s)),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: fit.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < s.targets.length; i++) ...[
                  if (i > 0) const SizedBox(height: kpiGap),
                  Expanded(
                    child: _KpiCard(
                      index: i + 1,
                      target: s.targets[i],
                      fit: fit,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 32),
          Expanded(child: _Panel(s)),
        ],
      ),
    );
  }
}

/// The pill at the top right. Its height does not change with the words.
class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  static const _steps = <FitStep>[
    (28, 1),
    (26, 1),
    (24, 1),
    (22, 1),
    (20, 1),
    (18, 1),
    (16, 1),
  ];

  @override
  Widget build(BuildContext context) {
    TextStyle style(double size) => st(
      size,
      weight: FontWeight.w700,
      color: Colors.white,
      // One line is always 39.2 px tall, so the pill keeps its height.
      height: 28 * 1.4 / size,
    );
    // 420 wide, no side padding of its own: keep 24 px of air on both sides.
    final f = pickFit(text, 420 - 48, _steps, style);
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
      decoration: BoxDecoration(
        color: SlidePalette.navy,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style(f.$1),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.index,
    required this.target,
    required this.fit,
  });

  final int index;
  final SnapshotTarget target;
  final KpiFit fit;

  @override
  Widget build(BuildContext context) {
    final color = SlidePalette.statusColor(target.status);
    final word = SlidePalette.statusWord(target.status);
    final text = Text(
      target.text,
      style: st(fit.fontSize, weight: FontWeight.w700, height: 1.2),
    );
    return Container(
      decoration: BoxDecoration(
        color: SlidePalette.card,
        border: Border.all(color: SlidePalette.cardBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: fit.label
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KPI $index · $word',
                    style: st(
                      24,
                      weight: FontWeight.w700,
                      color: color,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  text,
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 124,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        word,
                        style: st(
                          24,
                          weight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: text),
                ],
              ),
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel(this.s);

  final ReportSnapshot s;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 48),
      decoration: BoxDecoration(
        color: SlidePalette.navy,
        borderRadius: BorderRadius.circular(24),
      ),
      child: s.hasCounts ? _Volumes(s) : _TargetsOnly(s),
    );
  }
}

class _Volumes extends StatelessWidget {
  const _Volumes(this.s);

  final ReportSnapshot s;

  @override
  Widget build(BuildContext context) {
    if (s.metrics.length > 3) return _VolumesMany(s);
    final three = s.metrics.length >= 3;
    final bw = three ? 64.0 : 80.0;
    final big = three ? 56.0 : 72.0;
    final peak = math.max(
      1,
      s.metrics.expand((m) => m.values).fold<int>(0, math.max),
    );
    final scale = 190 / peak;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Volumes per month, ${s.firstMonthName} to ${s.lastMonthName}',
          style: st(32, weight: FontWeight.w700, color: SlidePalette.paper),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < s.metrics.length; i++) ...[
              if (i > 0) const SizedBox(width: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thousands(s.metrics[i].total),
                      style: st(
                        big,
                        weight: FontWeight.w700,
                        color: seriesColor(s.metrics[i].series),
                        height: 1.05,
                      ),
                    ),
                    Text(
                      '${s.metrics[i].label} in total',
                      style: st(
                        24,
                        color: SlidePalette.panelText,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var m = 0; m < 3; m++) ...[
              if (m > 0) const SizedBox(width: 24),
              Expanded(
                child: _MonthGroup(s: s, month: m, bw: bw, scale: scale),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _MonthGroup extends StatelessWidget {
  const _MonthGroup({
    required this.s,
    required this.month,
    required this.bw,
    required this.scale,
    this.gap = 12,
    this.labelSize = 28,
    this.labelHeight,
    this.rotated = false,
  });

  final ReportSnapshot s;
  final int month;
  final double bw;
  final double scale;
  final double gap;
  final double labelSize;
  final double? labelHeight;
  final bool rotated;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < s.metrics.length; i++) ...[
              if (i > 0) SizedBox(width: gap),
              _Bar(
                width: bw,
                value: s.metrics[i].values[month],
                color: seriesColor(s.metrics[i].series),
                scale: scale,
                labelSize: labelSize,
                labelHeight: labelHeight,
                rotated: rotated,
              ),
            ],
          ],
        ),
        Container(
          margin: const EdgeInsets.only(top: 0),
          padding: const EdgeInsets.only(top: 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: SlidePalette.axis, width: 2)),
          ),
          child: Text(
            s.months[month].short,
            textAlign: TextAlign.center,
            style: st(28, color: SlidePalette.panelText),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.width,
    required this.value,
    required this.color,
    required this.scale,
    this.labelSize = 28,
    this.labelHeight,
    this.rotated = false,
  });

  final double width;
  final int value;
  final Color color;
  final double scale;
  final double labelSize;
  final double? labelHeight;
  final bool rotated;

  @override
  Widget build(BuildContext context) {
    final h = math.max(value > 0 ? 6 : 3, (value * scale).round()).toDouble();
    final label = Text(
      thousands(value),
      softWrap: false,
      style: st(labelSize, weight: FontWeight.w700, color: SlidePalette.paper),
    );
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: labelHeight ?? 28 * 1.4,
            child: rotated
                ? OverflowBox(
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: Alignment.bottomCenter,
                    child: RotatedBox(quarterTurns: 3, child: label),
                  )
                : OverflowBox(maxWidth: double.infinity, child: label),
          ),
          const SizedBox(height: 4),
          Container(
            width: width,
            height: h,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Four to eight series: smaller totals in rows of three, narrower bars,
/// rotated value labels from five series on.
class _VolumesMany extends StatelessWidget {
  const _VolumesMany(this.s);

  final ReportSnapshot s;

  @override
  Widget build(BuildContext context) {
    final n = s.metrics.length;
    final big = n <= 6 ? 44.0 : 34.0;
    final small = n <= 6 ? 20.0 : 16.0;
    final lines = n <= 6 ? 2 : 3;
    final rows = (n / 3).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Volumes per month, ${s.firstMonthName} to ${s.lastMonthName}',
          style: st(32, weight: FontWeight.w700, color: SlidePalette.paper),
        ),
        const SizedBox(height: 12),
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < 3; c++) ...[
                if (c > 0) const SizedBox(width: 24),
                Expanded(
                  child: r * 3 + c < n
                      ? _Total(
                          m: s.metrics[r * 3 + c],
                          big: big,
                          small: small,
                          lines: lines,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 10),
        Expanded(child: LayoutBuilder(builder: _chart)),
      ],
    );
  }

  Widget _chart(BuildContext context, BoxConstraints box) {
    final n = s.metrics.length;
    final gap = n <= 5 ? 8.0 : 6.0;
    final gw = (box.maxWidth - 2 * 24) / 3;
    final bw = math.min(64.0, ((gw - 8 - gap * (n - 1)) / n).floorToDouble());
    final rotated = n >= 5;
    final labelSize = n == 4 ? 22.0 : (n <= 6 ? 18.0 : 16.0);
    final longest = s.metrics
        .expand((m) => m.values)
        .map((v) => thousands(v).length)
        .fold<int>(1, math.max);
    final labelHeight = rotated
        ? longest * 0.62 * labelSize + 6
        : labelSize * 1.4;
    const monthLabel = 58.0;
    final room = box.maxHeight - monthLabel - labelHeight - 8;
    final peak = math.max(
      1,
      s.metrics.expand((m) => m.values).fold<int>(0, math.max),
    );
    final scale = math.max(0.0, math.min(190.0, room)) / peak;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var m = 0; m < 3; m++) ...[
          if (m > 0) const SizedBox(width: 24),
          Expanded(
            child: _MonthGroup(
              s: s,
              month: m,
              bw: bw,
              scale: scale,
              gap: gap,
              labelSize: labelSize,
              labelHeight: labelHeight,
              rotated: rotated,
            ),
          ),
        ],
      ],
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({
    required this.m,
    required this.big,
    required this.small,
    required this.lines,
  });

  final SnapshotMetric m;
  final double big;
  final double small;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            thousands(m.total),
            style: st(
              big,
              weight: FontWeight.w700,
              color: seriesColor(m.series),
              height: 1.05,
            ),
          ),
        ),
        Text(
          '${m.label} in total',
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: st(small, color: SlidePalette.panelText, height: 1.2),
        ),
      ],
    );
  }
}

class _TargetsOnly extends StatelessWidget {
  const _TargetsOnly(this.s);

  final ReportSnapshot s;

  @override
  Widget build(BuildContext context) {
    final numbers = [
      (s.count(KpiStatus.met), 'Met', const Color(0xFF5FD3B0)),
      (s.count(KpiStatus.partly), 'Partly', const Color(0xFFF0C24A)),
      (s.count(KpiStatus.missed), 'Missed', const Color(0xFFF0933A)),
    ];
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Targets, ${s.firstMonthName} to ${s.lastMonthName}',
          style: st(32, weight: FontWeight.w700, color: SlidePalette.paper),
        ),
        Wrap(
          spacing: 56,
          runSpacing: 24,
          children: [
            for (final (n, label, color) in numbers)
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$n',
                    style: st(
                      120,
                      weight: FontWeight.w700,
                      color: color,
                      height: 1.05,
                    ),
                  ),
                  Text(label, style: st(28, color: SlidePalette.panelText)),
                ],
              ),
          ],
        ),
        Text(
          'This role has no monthly counts to chart.',
          style: st(24, color: SlidePalette.mutedOnDark),
        ),
      ],
    );
  }
}
