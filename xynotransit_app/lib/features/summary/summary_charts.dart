import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/period.dart';
import '../../domain/summary.dart';
import 'summary_widgets.dart';

TextStyle _axis(BuildContext context) =>
    monoStyle(context, size: 11, color: context.tokens.muted);

String _monthLabel(MonthRef m) => '${m.short} ${m.year}';

// ---------------------------------------------------------------------------
// 1. Who has reported
// ---------------------------------------------------------------------------

/// Submitted against missing per team, plus an overall ring.
class ReportedCard extends StatelessWidget {
  const ReportedCard({super.key, required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = summary;
    final missing = math.max(0, s.expected - s.submitted);
    final text = StringBuffer(
      'Who has reported: ${s.submitted} of ${s.expected} reports sent. ',
    );
    for (final team in s.teams) {
      text.write('${team.name}: ${team.submitted} of ${team.expected}. ');
    }
    return ChartCard(
      title: 'Who has reported',
      explain: 'Reports sent against reports expected, for each team.',
      child: ChartText(
        label: text.toString().trim(),
        child: LayoutBuilder(
          builder: (context, c) {
            final ring = _Ring(
              sent: s.submitted,
              missing: missing,
              expected: s.expected,
            );
            final bars = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Legend(
                    items: [
                      LegendItem(color: t.ok, label: 'Sent'),
                      LegendItem(color: t.warn, label: 'Still missing'),
                    ],
                  ),
                ),
                for (final team in s.teams)
                  BarRow(
                    label: team.name,
                    value: '${team.submitted} of ${team.expected}',
                    bar: StackedBar(
                      parts: [
                        BarPart(team.submitted, t.ok),
                        BarPart(
                          math.max(0, team.expected - team.submitted),
                          t.warn,
                        ),
                      ],
                    ),
                  ),
              ],
            );
            if (c.maxWidth >= 520) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ring,
                  const SizedBox(width: 24),
                  Expanded(child: bars),
                ],
              );
            }
            return Column(children: [ring, const SizedBox(height: 16), bars]);
          },
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.sent,
    required this.missing,
    required this.expected,
  });

  final int sent;
  final int missing;
  final int expected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final share = expected == 0 ? 0.0 : sent / expected;
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              startDegreeOffset: -90,
              sectionsSpace: sent > 0 && missing > 0 ? 2 : 0,
              centerSpaceRadius: 48,
              sections: [
                if (sent > 0)
                  PieChartSectionData(
                    value: sent.toDouble(),
                    color: t.ok,
                    radius: 22,
                    showTitle: false,
                  ),
                if (missing > 0)
                  PieChartSectionData(
                    value: missing.toDouble(),
                    color: t.warn,
                    radius: 22,
                    showTitle: false,
                  ),
                if (sent == 0 && missing == 0)
                  PieChartSectionData(
                    value: 1,
                    color: t.soft,
                    radius: 22,
                    showTitle: false,
                  ),
              ],
              pieTouchData: PieTouchData(enabled: false),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fmtPct(share),
                style: bodyStyle(
                  context,
                  size: 24,
                  weight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              Text(
                'sent',
                style: bodyStyle(
                  context,
                  size: 13,
                  color: t.muted,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. How targets went
// ---------------------------------------------------------------------------

class TargetsCard extends StatelessWidget {
  const TargetsCard({super.key, required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = summary;
    final text = StringBuffer(
      'How targets went: ${s.met} met, ${s.partly} partly met, '
      '${s.missed} missed. ',
    );
    for (final team in s.teams) {
      text.write(
        '${team.name}: ${team.met} met, ${team.partly} partly, '
        '${team.missed} missed. ',
      );
    }
    return ChartCard(
      title: 'How targets went',
      explain:
          'Every answered target, split into met, partly met and missed. '
          'Each bar is 100 percent of that team.',
      child: ChartText(
        label: text.toString().trim(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Legend(
                items: [
                  LegendItem(color: t.ok, label: 'Met'),
                  LegendItem(color: t.warn, label: 'Partly met'),
                  LegendItem(color: t.bad, label: 'Missed'),
                ],
              ),
            ),
            for (final team in s.teams)
              BarRow(
                label: team.name,
                value: team.answered == 0
                    ? 'No answers'
                    : '${fmtPct(team.metRate)} met',
                bar: StackedBar(
                  parts: [
                    BarPart(team.met, t.ok),
                    BarPart(team.partly, t.warn),
                    BarPart(team.missed, t.bad),
                  ],
                ),
                footer: Text(
                  '${team.met} met · ${team.partly} partly · '
                  '${team.missed} missed',
                  style: bodyStyle(
                    context,
                    size: 13,
                    color: t.muted,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Volume by month
// ---------------------------------------------------------------------------

class VolumeCard extends StatelessWidget {
  const VolumeCard({super.key, required this.summary});

  final Summary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = summary;
    final months = s.months;
    final monthTotals = [
      for (var i = 0; i < months.length; i++)
        s.teams.fold<int>(0, (a, team) => a + _at(team.volumeByMonth, i)),
    ];
    final maxTotal = monthTotals.fold<int>(0, math.max);
    final text = StringBuffer('Volume by month: ');
    for (var i = 0; i < months.length; i++) {
      text.write('${_monthLabel(months[i])} ${fmtInt(monthTotals[i])}');
      final parts = [
        for (final team in s.teams)
          if (_at(team.volumeByMonth, i) > 0)
            '${team.name} ${fmtInt(_at(team.volumeByMonth, i))}',
      ];
      if (parts.isNotEmpty) text.write(' (${parts.join(', ')})');
      text.write('. ');
    }
    return ChartCard(
      title: 'Volume by month',
      explain: 'All counts added together for each month, one colour per team.',
      child: maxTotal == 0
          ? Text(
              'No counts have been entered yet.',
              style: bodyStyle(context, color: t.muted),
            )
          : ChartText(
              label: text.toString().trim(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 260,
                    child: _VolumeChart(
                      summary: s,
                      maxTotal: maxTotal,
                      tokens: t,
                      axis: _axis(context),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Legend(
                    items: [
                      for (var i = 0; i < s.teams.length; i++)
                        LegendItem(
                          color: seriesColor(i),
                          label: s.teams[i].name,
                        ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

int _at(List<int> l, int i) => i < l.length ? l[i] : 0;

class _VolumeChart extends StatelessWidget {
  const _VolumeChart({
    required this.summary,
    required this.maxTotal,
    required this.tokens,
    required this.axis,
  });

  final Summary summary;
  final int maxTotal;
  final XynoTokens tokens;
  final TextStyle axis;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final top = _niceTop(maxTotal);
    final groups = <BarChartGroupData>[];
    for (var m = 0; m < s.months.length; m++) {
      var from = 0.0;
      final stack = <BarChartRodStackItem>[];
      for (var i = 0; i < s.teams.length; i++) {
        final v = _at(s.teams[i].volumeByMonth, m).toDouble();
        if (v <= 0) continue;
        stack.add(
          BarChartRodStackItem(
            from,
            from + v,
            seriesColor(i),
            // A thin gap between teams keeps neighbours apart for people
            // who cannot tell the colours apart.
            borderSide: BorderSide(color: tokens.surface, width: 1.5),
          ),
        );
        from += v;
      }
      groups.add(
        BarChartGroupData(
          x: m,
          barRods: [
            BarChartRodData(
              toY: from,
              width: 44,
              color: tokens.soft,
              rodStackItems: stack,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          ],
        ),
      );
    }
    return BarChart(
      BarChartData(
        maxY: top,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        barGroups: groups,
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: top / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: tokens.line, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            axisNameSize: 20,
            axisNameWidget: Text('Total of all counts', style: axis),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: top / 4,
              getTitlesWidget: (v, meta) => SideTitleWidget(
                meta: meta,
                child: Text(fmtCompact(v), style: axis),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            axisNameSize: 20,
            axisNameWidget: Text('Month', style: axis),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= s.months.length) return const SizedBox();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(s.months[i].short, style: axis),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => tokens.ink,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItem: (group, gi, rod, ri) {
              final m = group.x;
              final lines = <String>[_monthLabel(s.months[m])];
              for (final team in s.teams) {
                final v = _at(team.volumeByMonth, m);
                if (v > 0) lines.add('${team.name}: ${fmtInt(v)}');
              }
              lines.add('Total: ${fmtInt(rod.toY)}');
              return BarTooltipItem(
                lines.join('\n'),
                TextStyle(
                  fontFamily: XynoTokens.sans,
                  fontSize: 12,
                  color: tokens.bg,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A round number a little above [max], so four grid lines sit on whole values.
double _niceTop(int max) {
  if (max <= 4) return 4;
  final mag = math.pow(10, (math.log(max) / math.ln10).floor()).toDouble();
  for (final step in [1, 2, 2.5, 5, 10]) {
    final top = step * mag;
    if (top >= max) return top;
  }
  return max.toDouble();
}

// ---------------------------------------------------------------------------
// 4. Biggest counts
// ---------------------------------------------------------------------------

class BiggestCard extends StatefulWidget {
  const BiggestCard({super.key, required this.summary});

  final Summary summary;

  @override
  State<BiggestCard> createState() => _BiggestCardState();
}

class _BiggestCardState extends State<BiggestCard> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = widget.summary;
    if (s.metrics.isEmpty) {
      return ChartCard(
        title: 'Biggest counts',
        explain: 'The counts with the highest totals this period.',
        child: Text(
          'No counts have been entered yet.',
          style: bodyStyle(context, color: t.muted),
        ),
      );
    }
    final top = s.metrics.take(8).toList();
    final peak = top.first.total <= 0 ? 1 : top.first.total;
    final selected = s.metrics.firstWhere(
      (m) => m.label == _picked,
      orElse: () => s.metrics.first,
    );
    final topText = [for (final m in top) '${m.label} ${fmtInt(m.total)}']
        .join(', ');
    return ChartCard(
      title: 'Biggest counts',
      explain:
          'The ${top.length} counts with the highest totals. Pick any count '
          'below to see its months and teams.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChartText(
            label: 'Biggest counts by total: $topText.',
            child: Column(
              children: [
                for (var i = 0; i < top.length; i++)
                  BarRow(
                    label: top[i].label,
                    value: fmtInt(top[i].total),
                    bar: _SingleBar(
                      value: top[i].total,
                      peak: peak,
                      // One colour: each bar is named, and the team colours
                      // of the volume chart must keep their own meaning.
                      color: t.accent,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Labeled(
            label: 'Look at one count',
            child: DropdownButtonFormField<String>(
              key: const ValueKey('metric-picker'),
              initialValue: selected.label,
              isExpanded: true,
              decoration: xInput(context),
              items: [
                for (final m in s.metrics)
                  DropdownMenuItem(
                    value: m.label,
                    child: Text(m.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _picked = v),
            ),
          ),
          const SizedBox(height: 16),
          _MetricDetail(metric: selected, months: s.months),
        ],
      ),
    );
  }
}

class _SingleBar extends StatelessWidget {
  const _SingleBar({
    required this.value,
    required this.peak,
    required this.color,
  });

  final int value;
  final int peak;
  final Color color;

  @override
  Widget build(BuildContext context) => StackedBar(
    parts: [BarPart(1, color)],
    fraction: peak == 0 ? 0 : value / peak,
  );
}

class _MetricDetail extends StatelessWidget {
  const _MetricDetail({required this.metric, required this.months});

  final MetricSummary metric;
  final List<MonthRef> months;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final monthPeak = metric.byMonth.fold<int>(1, math.max);
    final teamPeak = metric.byTeam.fold<int>(1, (a, b) => math.max(a, b.total));
    final text = StringBuffer(
      '${metric.label}: total ${fmtInt(metric.total)}. By month: ',
    );
    text.write(
      [
        for (var i = 0; i < months.length; i++)
          '${_monthLabel(months[i])} ${fmtInt(_at(metric.byMonth, i))}',
      ].join(', '),
    );
    text.write('. By team: ');
    text.write(
      [for (final b in metric.byTeam) '${b.team} ${fmtInt(b.total)}']
          .join(', '),
    );
    text.write('.');
    Widget head(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        s.toUpperCase(),
        style: monoStyle(
          context,
          size: 12,
          color: t.muted,
        ).copyWith(letterSpacing: 12 * 0.08),
      ),
    );
    return ChartText(
      label: text.toString(),
      child: Column(
        key: const ValueKey('metric-detail'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${metric.label}: ${fmtInt(metric.total)} in total',
            style: bodyStyle(context, weight: FontWeight.w700, size: 16),
          ),
          const SizedBox(height: 10),
          head('By month'),
          for (var i = 0; i < months.length; i++)
            BarRow(
              label: _monthLabel(months[i]),
              value: fmtInt(_at(metric.byMonth, i)),
              bar: _SingleBar(
                value: _at(metric.byMonth, i),
                peak: monthPeak,
                color: t.accent,
              ),
            ),
          head('By team'),
          for (final b in metric.byTeam)
            BarRow(
              label: b.team,
              value: fmtInt(b.total),
              bar: _SingleBar(value: b.total, peak: teamPeak, color: t.accent),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Trend over periods
// ---------------------------------------------------------------------------

class TrendCard extends StatelessWidget {
  const TrendCard({super.key, required this.summary});

  final Summary summary;

  static String shortLabel(TrendPoint p) {
    final y = p.startMonth.year % 100;
    return '${_months[p.startMonth.month - 1]} ${y.toString().padLeft(2, '0')}';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pts = summary.trend;
    final text = StringBuffer('Trend over periods: ');
    for (final p in pts) {
      text.write(
        '${p.label}: ${p.submitted} of ${p.expected} reports sent '
        '(${fmtPct(p.submissionRate)}), '
        '${p.answered == 0 ? 'no targets answered' : '${fmtPct(p.metRate)} of targets met'}. ',
      );
    }
    final axis = _axis(context);
    return ChartCard(
      title: 'Trend over periods',
      explain:
          'Share of expected reports that were sent, and share of answered '
          'targets that were met, for the latest periods. The start month of '
          'each period is on the bottom.',
      child: pts.isEmpty
          ? Text(
              'There is nothing to compare yet.',
              style: bodyStyle(context, color: t.muted),
            )
          : ChartText(
              label: text.toString().trim(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Legend(
                      items: [
                        LegendItem(color: t.accent, label: 'Reports sent'),
                        LegendItem(color: t.ok, label: 'Targets met'),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 220,
                    child: LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: 100,
                        minX: -0.5,
                        maxX: pts.length - 0.5,
                        gridData: FlGridData(
                          drawVerticalLine: false,
                          horizontalInterval: 25,
                          getDrawingHorizontalLine: (_) =>
                              FlLine(color: t.line, strokeWidth: 1),
                        ),
                        borderData: FlBorderData(show: false),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(),
                          rightTitles: const AxisTitles(),
                          leftTitles: AxisTitles(
                            axisNameSize: 20,
                            axisNameWidget: Text('Percent', style: axis),
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 40,
                              interval: 25,
                              getTitlesWidget: (v, meta) => SideTitleWidget(
                                meta: meta,
                                child: Text('${v.toInt()}%', style: axis),
                              ),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 26,
                              interval: 1,
                              getTitlesWidget: (v, meta) {
                                final i = v.round();
                                if ((v - i).abs() > 0.01 ||
                                    i < 0 ||
                                    i >= pts.length) {
                                  return const SizedBox();
                                }
                                return SideTitleWidget(
                                  meta: meta,
                                  child: Text(shortLabel(pts[i]), style: axis),
                                );
                              },
                            ),
                          ),
                        ),
                        lineTouchData: LineTouchData(
                          touchTooltipData: LineTouchTooltipData(
                            getTooltipColor: (_) => t.ink,
                            fitInsideHorizontally: true,
                            getTooltipItems: (spots) => [
                              for (final sp in spots)
                                LineTooltipItem(
                                  '${sp.barIndex == 0 ? 'Reports sent' : 'Targets met'}'
                                  ' ${sp.y.round()}%\n${pts[sp.x.round()].label}',
                                  TextStyle(
                                    fontFamily: XynoTokens.sans,
                                    fontSize: 12,
                                    color: t.bg,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        lineBarsData: [
                          _line(
                            [
                              for (var i = 0; i < pts.length; i++)
                                FlSpot(
                                  i.toDouble(),
                                  pts[i].submissionRate * 100,
                                ),
                            ],
                            t.accent,
                            t,
                          ),
                          _line(
                            [
                              for (var i = 0; i < pts.length; i++)
                                if (pts[i].answered > 0)
                                  FlSpot(i.toDouble(), pts[i].metRate * 100),
                            ],
                            t.ok,
                            t,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TrendValues(points: pts),
                ],
              ),
            ),
    );
  }

  LineChartBarData _line(List<FlSpot> spots, Color color, XynoTokens t) =>
      LineChartBarData(
        spots: spots,
        color: color,
        barWidth: 3,
        isCurved: false,
        dotData: FlDotData(
          getDotPainter: (spot, p, bar, i) => FlDotCirclePainter(
            radius: 4.5,
            color: color,
            strokeColor: t.surface,
            strokeWidth: 2,
          ),
        ),
      );
}

/// The numbers behind every point, as text under the lines.
class _TrendValues extends StatelessWidget {
  const _TrendValues({required this.points});

  final List<TrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    TextStyle style(Color c) =>
        monoStyle(context, size: 12, color: c, weight: FontWeight.w500);
    // Same room as the chart's left axis (name 20 + labels 40), so every
    // column sits under its own point.
    return Padding(
      padding: const EdgeInsets.only(left: 60),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in points)
            Expanded(
              child: Column(
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      fmtPct(p.submissionRate),
                      style: style(t.accent),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      p.answered == 0 ? '–' : fmtPct(p.metRate),
                      style: style(t.ok),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
