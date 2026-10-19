import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import '../../domain/enums.dart';
import '../../domain/snapshot.dart';
import 'canvas.dart';
import 'fit.dart';
import 'icons.dart';
import 'measure.dart';
import 'palette.dart';
import 'slide_words.dart';
import 'volumes_chart.dart';

/// Slide 1 of 2: targets on the left, monthly volumes on the right.
class SlideKpi extends StatelessWidget {
  const SlideKpi(this.snapshot, {super.key, this.texts = DeckTexts.empty});

  final ReportSnapshot snapshot;
  final DeckTexts texts;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final w = SlideWords(texts);
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
      // The heading may take one to five lines, the body gets what is left.
      body: LayoutBuilder(
        builder: (context, box) {
          if (s.targets.isEmpty) return _Panel(s);
          final fitted = s.targets.length > 6
              ? null
              : fitKpis([
                  for (final t in s.targets) t.text,
                ], area: box.maxHeight);
          final grid = fitted == null || fitted.dense;
          final fit = grid
              ? const KpiFit(width: kpiGridWidth, label: false, fontSize: 22)
              : fitted;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: fit.width,
                child: grid
                    ? _KpiGrid(s.targets, area: box.maxHeight)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < s.targets.length; i++) ...[
                            if (i > 0) const SizedBox(height: kpiGap),
                            Expanded(
                              child: _KpiCard(
                                index: i + 1,
                                target: s.targets[i],
                                fit: fit,
                                few: s.targets.length <= 2,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(width: 32),
              Expanded(child: _Panel(s)),
            ],
          );
        },
      ),
    );
  }
}

/// Seven to ten targets: two columns of compact cards, a status chip above
/// the text. Text is never below 20 px; a text that does not fit is cut with
/// an ellipsis here (the full text stays in the alt text and notes).
class _KpiGrid extends StatelessWidget {
  const _KpiGrid(this.targets, {required this.area});

  final List<SnapshotTarget> targets;
  final double area;

  static const _chipFs = 20.0;
  static const _chipHeight = _chipFs * 1.2 + 6;
  static const _textWidth = (kpiGridWidth - kpiGap) / 2 - 40 - 2;

  /// The biggest type (26 px down to 20 px) in which every text shows in
  /// full; at 20 px a longer text ends with an ellipsis.
  static ({double fs, int lines, double pad}) plan(
    List<SnapshotTarget> targets,
    double area,
  ) {
    final rows = (targets.length / 2).ceil();
    final cardHeight = (area - (rows - 1) * kpiGap) / rows;
    final pad = rows <= 4 ? 12.0 : 8.0;
    int linesFor(double fs) => math.max(
      1,
      ((cardHeight - 2 - 2 * pad - _chipHeight - 6) / (fs * 1.2)).floor(),
    );
    for (final fs in const [26.0, 24.0, 22.0, 20.0]) {
      final lines = linesFor(fs);
      final fits = targets.every(
        (t) => !measureText(
          t.text,
          kpiTextStyle(fs),
          _textWidth,
          maxLines: lines,
        ).exceeded,
      );
      if (fits || fs == 20) return (fs: fs, lines: lines, pad: pad);
    }
    return (fs: 20, lines: linesFor(20), pad: pad);
  }

  @override
  Widget build(BuildContext context) {
    final rows = (targets.length / 2).ceil();
    final p = plan(targets, area);
    Widget cell(int i) {
      if (i >= targets.length) return const SizedBox.shrink();
      return _GridCard(
        target: targets[i],
        fontSize: p.fs,
        chipFontSize: _chipFs,
        lines: p.lines,
        pad: p.pad,
      );
    }

    return Column(
      children: [
        for (var r = 0; r < rows; r++) ...[
          if (r > 0) const SizedBox(height: kpiGap),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: cell(r * 2)),
                const SizedBox(width: kpiGap),
                Expanded(child: cell(r * 2 + 1)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _GridCard extends StatelessWidget {
  const _GridCard({
    required this.target,
    required this.fontSize,
    required this.chipFontSize,
    required this.lines,
    required this.pad,
  });

  final SnapshotTarget target;
  final double fontSize;
  final double chipFontSize;
  final int lines;
  final double pad;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: pad, horizontal: 20),
      decoration: BoxDecoration(
        color: SlidePalette.card,
        border: Border.all(color: SlidePalette.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            decoration: BoxDecoration(
              color: SlidePalette.statusColor(target.status),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (target.status != null) ...[
                  StatusGlyph(
                    target.status,
                    Colors.white,
                    size: chipFontSize * 0.9,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  SlidePalette.statusWord(target.status),
                  maxLines: 1,
                  style: st(
                    chipFontSize,
                    weight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 1,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            target.text,
            maxLines: lines,
            overflow: TextOverflow.ellipsis,
            style: kpiTextStyle(fontSize),
          ),
        ],
      ),
    );
  }
}

/// The pill at the top right. Its height does not change with the words as
/// long as they fit one line; a long text takes two lines at 20 px.
class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  static const _sizes = [28.0, 26.0, 24.0, 22.0, 20.0];

  TextStyle _style(double size, int lines) => st(
    size,
    weight: FontWeight.w700,
    color: Colors.white,
    // One line is always 39.2 px tall, so the pill keeps its height.
    height: lines == 1 ? 28 * 1.4 / size : 1.2,
  );

  /// The biggest size that fits one line, else 20 px on two lines.
  (double, int) _pick() {
    // 420 wide, no side padding of its own: keep 24 px of air on both sides.
    for (final z in _sizes) {
      final m = measureText(text, _style(z, 1), 420 - 48, maxLines: 1);
      if (!m.exceeded) return (z, 1);
    }
    return (20, 2);
  }

  @override
  Widget build(BuildContext context) {
    final (size, lines) = _pick();
    return Container(
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
        vertical: lines == 1 ? 10 : 12,
        horizontal: 24,
      ),
      decoration: BoxDecoration(
        color: SlidePalette.navy,
        borderRadius: BorderRadius.circular(lines == 1 ? 999 : 36),
      ),
      child: Text(
        text,
        maxLines: lines,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: _style(size, lines),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.index,
    required this.target,
    required this.fit,
    required this.few,
  });

  final int index;
  final SnapshotTarget target;
  final KpiFit fit;

  /// One or two targets: bigger status label.
  final bool few;

  @override
  Widget build(BuildContext context) {
    final color = SlidePalette.statusColor(target.status);
    final word = SlidePalette.statusWord(target.status);
    final text = Text(target.text, style: kpiTextStyle(fit.fontSize));
    return Container(
      decoration: BoxDecoration(
        color: SlidePalette.card,
        border: Border.all(color: SlidePalette.cardBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: fit.label
          ? Padding(
              padding: const EdgeInsets.symmetric(
                vertical: kpiLabelPad,
                horizontal: 40,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (target.status != null) ...[
                        StatusGlyph(target.status, color, size: 22),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        'KPI $index · $word',
                        style: st(
                          24,
                          weight: FontWeight.w700,
                          color: color,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  text,
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(
                vertical: kpiChipPad,
                horizontal: 28,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: kpiChipWidth,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(
                      vertical: 5,
                      horizontal: 6,
                    ),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (target.status != null) ...[
                          StatusGlyph(target.status, Colors.white, size: 18),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            word,
                            textAlign: TextAlign.center,
                            style: st(
                              20,
                              weight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 1,
                              height: 1.15,
                            ),
                          ),
                        ),
                      ],
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

/// The dark panel: volumes per month, or only the target totals when the role
/// has no counts. With no targets it takes the whole width of the slide.
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
      child: s.hasCounts ? VolumesChart(s) : _TargetsOnly(s),
    );
  }
}

class _TargetsOnly extends StatelessWidget {
  const _TargetsOnly(this.s);

  final ReportSnapshot s;

  @override
  Widget build(BuildContext context) {
    final numbers = [
      (s.count(KpiStatus.met), 'Met', SlidePalette.metOnNavy),
      (s.count(KpiStatus.partly), 'Partly', SlidePalette.partlyOnNavy),
      (s.count(KpiStatus.missed), 'Missed', SlidePalette.missedOnNavy),
    ];
    final none = s.targets.isEmpty;
    if (none) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Targets, ${s.firstMonthName} to ${s.lastMonthName}',
            style: st(32, weight: FontWeight.w700, color: SlidePalette.paper),
          ),
          Expanded(
            child: Center(
              child: Text(
                'This role has no targets and no monthly counts.',
                textAlign: TextAlign.center,
                style: st(32, color: SlidePalette.panelText),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Targets, ${s.firstMonthName} to ${s.lastMonthName}',
          style: st(32, weight: FontWeight.w700, color: SlidePalette.paper),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (n, label, color) in numbers)
              Expanded(
                child: Column(
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
