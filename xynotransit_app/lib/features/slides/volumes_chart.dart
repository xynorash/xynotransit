import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme/tokens.dart' show seriesColor;
import '../../domain/snapshot.dart';
import 'canvas.dart';
import 'measure.dart';
import 'palette.dart';

/// The monthly volumes of a person: totals on top, three groups of bars below.
///
/// Everything is a pure function of the words and the size of the panel. The
/// totals use the largest type that fits, the value labels turn on their side
/// when the bars are too close, and the bars take all the height that is left.
/// Nothing is scaled down below 20 px (18 px for the value labels).
class VolumesChart extends StatelessWidget {
  const VolumesChart(this.snapshot, {super.key});

  final ReportSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => _build(planVolumes(snapshot, box.biggest)),
    );
  }

  Widget _build(VolumesPlan p) {
    final s = snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(p.title, maxLines: 1, style: _titleStyle),
        const SizedBox(height: _titleGap),
        _Legend(s: s, plan: p),
        const SizedBox(height: _legendGap),
        Expanded(
          child: _Chart(s: s, plan: p),
        ),
      ],
    );
  }
}

const _titleGap = 20.0;
const _legendGap = 16.0;
const _groupGap = 24.0;
const _monthTop = 12.0;

final _titleStyle = st(32, weight: FontWeight.w700, color: SlidePalette.paper);

TextStyle _numberStyle(double size, Color color) =>
    st(size, weight: FontWeight.w700, color: color, height: 1.05);

TextStyle _labelStyle(double size) =>
    st(size, color: SlidePalette.panelText, height: 1.25);

TextStyle _barLabelStyle(double size) =>
    st(size, weight: FontWeight.w700, color: SlidePalette.paper, height: 1.2);

TextStyle get _monthStyle => st(28, color: SlidePalette.panelText);

double _width(String text, TextStyle style) =>
    measureText(text, style, double.infinity, maxLines: 1).width;

({double height, int lines}) _box(
  String text,
  TextStyle style,
  double width, {
  int? maxLines,
}) {
  final m = measureText(text, style, width, maxLines: maxLines);
  return (height: m.height, lines: m.lines);
}

/// How a panel of a given size is laid out.
class VolumesPlan {
  const VolumesPlan({
    required this.title,
    required this.cols,
    required this.numberSize,
    required this.labelSize,
    required this.labelLines,
    required this.legendHeight,
    required this.cellWidth,
    required this.groupGap,
    required this.barWidth,
    required this.barGap,
    required this.valueSize,
    required this.rotated,
    required this.slot,
    required this.monthHeight,
  });

  final String title;

  /// Columns of the totals grid, type sizes and the most lines of a label
  /// (null: as many as it needs).
  final int cols;
  final double numberSize;
  final double labelSize;
  final int? labelLines;
  final double legendHeight;
  final double cellWidth;

  final double groupGap;
  final double barWidth;
  final double barGap;

  /// Size of the number above a bar, and whether it is written upwards.
  final double valueSize;
  final bool rotated;

  /// Height reserved above the bars for those numbers.
  final double slot;
  final double monthHeight;

  @override
  String toString() =>
      'VolumesPlan(cols: $cols, num: $numberSize, label: $labelSize/$labelLines, '
      'legend: $legendHeight, bar: $barWidth, value: $valueSize rotated: $rotated)';
}

const _maxBar = {
  1: 112.0,
  2: 88.0,
  3: 72.0,
  4: 60.0,
  5: 52.0,
  6: 46.0,
  7: 40.0,
  8: 36.0,
};

const _colOptions = {
  1: [1],
  2: [2, 1],
  3: [3, 1],
  // Three to a row up to six counts. Seven and eight take two rows of four
  // so the bars keep their height.
  4: [3, 4, 2, 1],
  5: [3, 2, 1],
  6: [3, 2, 1],
  7: [4, 3, 2, 1],
  8: [4, 3, 2, 1],
};

const _numberLadder = [
  72.0,
  64.0,
  56.0,
  48.0,
  44.0,
  40.0,
  36.0,
  32.0,
  28.0,
  26.0,
  24.0,
];

String _in(SnapshotMetric m) => '${m.label} in total';

/// Pure: the same words and size always give the same plan.
VolumesPlan planVolumes(ReportSnapshot s, Size size) {
  final n = s.metrics.length;
  final w = size.width;
  final h = size.height;
  final title = 'Volumes per month, ${s.firstMonthName} to ${s.lastMonthName}';
  final titleH = _box(title, _titleStyle, w).height;

  // Bars and their numbers depend on the width only.
  final gap = n <= 2 ? 14.0 : (n <= 3 ? 12.0 : (n <= 5 ? 8.0 : 6.0));
  final gw = (w - 2 * _groupGap) / 3;
  final bw = math
      .min(_maxBar[n] ?? 36.0, ((gw - 12 - gap * (n - 1)) / n).floorToDouble())
      .clamp(8.0, 200.0)
      .toDouble();
  final pitch = bw + gap;
  final values = [for (final m in s.metrics) ...m.values.map(thousands)];
  double widest(double size) =>
      values.map((v) => _width(v, _barLabelStyle(size))).fold(0.0, math.max);
  var valueSize = 18.0;
  var rotated = true;
  // One count alone may use the whole width of its month.
  final labelRoom = n == 1 ? gw - 12 : pitch - 6;
  for (final z in [28.0, 24.0, 22.0, 20.0, 18.0]) {
    if (widest(z) <= labelRoom) {
      valueSize = z;
      rotated = false;
      break;
    }
  }
  if (rotated) {
    // Written upwards: the line thickness has to fit the pitch.
    for (final z in [22.0, 20.0, 18.0]) {
      valueSize = z;
      if (z * 1.2 <= pitch - 2) break;
    }
  }
  final slot = rotated ? widest(valueSize) + 10 : valueSize * 1.2 + 6;
  final monthH = _monthTop + 2 + _box('Aaa', _monthStyle, 100).height;
  final minBars = n >= 6 ? 60.0 : 90.0;
  final chartMin = monthH + slot + 6 + minBars;

  // Totals: the nicest grid that leaves the chart its minimum.
  final budget = h - titleH - _titleGap - _legendGap - chartMin;
  VolumesPlan plan({
    required int cols,
    required double ls,
    required int? lines,
  }) {
    final cw = (w - (cols - 1) * 24) / cols;
    final ladder = _numberLadder.where(
      (z) => z <= (n <= 3 ? 72 : (n <= 5 ? 44 : 36)),
    );
    var ns = ladder.last;
    for (final z in ladder) {
      final fits = s.metrics.every(
        (m) => _width(thousands(m.total), _numberStyle(z, Colors.white)) <= cw,
      );
      if (fits) {
        ns = z;
        break;
      }
    }
    final rows = (n / cols).ceil();
    var cellH = 0.0;
    for (final m in s.metrics) {
      final lh = _box(_in(m), _labelStyle(ls), cw, maxLines: lines).height;
      cellH = math.max(cellH, ns * 1.05 + lh);
    }
    return VolumesPlan(
      title: title,
      cols: cols,
      numberSize: ns,
      labelSize: ls,
      labelLines: lines,
      legendHeight: rows * cellH + (rows - 1) * 14,
      cellWidth: cw,
      groupGap: _groupGap,
      barWidth: bw,
      barGap: gap,
      valueSize: valueSize,
      rotated: rotated,
      slot: slot,
      monthHeight: monthH,
    );
  }

  final sizes = n <= 3 ? [24.0, 22.0, 20.0] : [22.0, 20.0];
  final colChoices = _colOptions[n] ?? [3];
  for (final ls in sizes) {
    for (final cols in colChoices) {
      final p = plan(cols: cols, ls: ls, lines: null);
      // A number must also fit its cell at 24 px or more.
      final numbersFit = s.metrics.every(
        (m) =>
            _width(thousands(m.total), _numberStyle(24, Colors.white)) <=
            p.cellWidth,
      );
      if (numbersFit && p.legendHeight <= budget) return p;
    }
  }
  // Nothing fits in full: the smallest type, and labels cut to the room there is.
  final cols = colChoices.first;
  for (var lines = 3; lines >= 1; lines--) {
    final p = plan(cols: cols, ls: 20, lines: lines);
    if (p.legendHeight <= budget || lines == 1) return p;
  }
  return plan(cols: cols, ls: 20, lines: 1);
}

class _Legend extends StatelessWidget {
  const _Legend({required this.s, required this.plan});

  final ReportSnapshot s;
  final VolumesPlan plan;

  @override
  Widget build(BuildContext context) {
    final n = s.metrics.length;
    final rows = (n / plan.cols).ceil();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < plan.cols; c++) ...[
                if (c > 0) const SizedBox(width: 24),
                SizedBox(
                  width: plan.cellWidth,
                  child: r * plan.cols + c < n
                      ? _Total(s.metrics[r * plan.cols + c], plan)
                      : null,
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.m, this.plan);

  final SnapshotMetric m;
  final VolumesPlan plan;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          thousands(m.total),
          maxLines: 1,
          softWrap: false,
          style: _numberStyle(plan.numberSize, seriesColor(m.series)),
        ),
        Text(
          _in(m),
          maxLines: plan.labelLines,
          overflow: plan.labelLines == null
              ? TextOverflow.clip
              : TextOverflow.ellipsis,
          style: _labelStyle(plan.labelSize),
        ),
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.s, required this.plan});

  final ReportSnapshot s;
  final VolumesPlan plan;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final room = math.max(
          0.0,
          box.maxHeight - plan.monthHeight - plan.slot - 6,
        );
        final peak = math.max(
          1,
          s.metrics.expand((m) => m.values).fold<int>(0, math.max),
        );
        final scale = room / peak;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var m = 0; m < 3; m++) ...[
              if (m > 0) SizedBox(width: plan.groupGap),
              Expanded(
                child: _MonthGroup(s: s, plan: plan, month: m, scale: scale),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MonthGroup extends StatelessWidget {
  const _MonthGroup({
    required this.s,
    required this.plan,
    required this.month,
    required this.scale,
  });

  final ReportSnapshot s;
  final VolumesPlan plan;
  final int month;
  final double scale;

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
              if (i > 0) SizedBox(width: plan.barGap),
              _Bar(
                plan: plan,
                value: s.metrics[i].values[month],
                color: seriesColor(s.metrics[i].series),
                scale: scale,
              ),
            ],
          ],
        ),
        Container(
          padding: const EdgeInsets.only(top: _monthTop),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: SlidePalette.axis, width: 2)),
          ),
          child: Text(
            s.months[month].short,
            textAlign: TextAlign.center,
            style: _monthStyle,
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.plan,
    required this.value,
    required this.color,
    required this.scale,
  });

  final VolumesPlan plan;
  final int value;
  final Color color;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final h = math.max(value > 0 ? 6 : 3, (value * scale).round()).toDouble();
    final label = Text(
      thousands(value),
      softWrap: false,
      maxLines: 1,
      style: _barLabelStyle(plan.valueSize),
    );
    return SizedBox(
      width: plan.barWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: plan.slot,
            child: OverflowBox(
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: plan.rotated
                    ? RotatedBox(quarterTurns: 3, child: label)
                    : label,
              ),
            ),
          ),
          Container(
            width: plan.barWidth,
            height: h,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(math.min(8, plan.barWidth / 3)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
