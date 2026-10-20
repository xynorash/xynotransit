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

/// The comment an employee typed under a target, as one trimmed line, or null.
String? targetComment(SnapshotTarget t) {
  final c = t.comment;
  if (c == null) return null;
  final one = c.trim().replaceAll(RegExp(r'\s+'), ' ');
  return one.isEmpty ? null : one;
}

/// Only a target that was not fully met shows the words behind it.
bool showsComment(SnapshotTarget t) =>
    (t.status == KpiStatus.partly || t.status == KpiStatus.missed) &&
    targetComment(t) != null;

final _commentStyle = st(20, color: SlidePalette.mutedOnLight, height: 1.2);

/// Height of the one line of comment under a target, and its gap.
const kpiCommentGap = 6.0;
final kpiCommentHeight = 20 * 1.2;

/// [comment] cut, at a word if it can be, with an ellipsis of its own so that
/// it fits one line of [width]. The whole comment stays in the speaker notes.
String commentLine(String comment, double width) {
  bool fits(String t) =>
      measureText(t, _commentStyle, double.infinity, maxLines: 1).width <=
      width;
  if (fits(comment)) return comment;
  var lo = 0, hi = comment.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (fits('${comment.substring(0, mid).trimRight()}\u2026')) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  var cut = comment.substring(0, lo);
  final space = cut.lastIndexOf(' ');
  // Back to the last whole word, unless that throws away most of the line.
  if (space > lo * 0.6 && lo < comment.length && comment[lo] != ' ') {
    cut = cut.substring(0, space);
  }
  return '${cut.trimRight()}\u2026';
}

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
              ? const KpiFit(width: kpiGridWidth, fontSize: 22)
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
                              child: _KpiCard(target: s.targets[i], fit: fit),
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
  const _KpiCard({required this.target, required this.fit});

  final SnapshotTarget target;
  final KpiFit fit;

  @override
  Widget build(BuildContext context) {
    final color = SlidePalette.statusColor(target.status);
    final word = SlidePalette.statusWord(target.status);
    final text = Text(target.text, style: kpiTextStyle(fit.fontSize));
    return LayoutBuilder(
      builder: (context, box) => _card(box.maxHeight, color, word, text),
    );
  }

  /// The comment line, when there is room for it under the text.
  Widget? _comment(double cardHeight) {
    if (!showsComment(target)) return null;
    final width = fit.width - 56 - kpiChipWidth - 16 - 2;
    final textHeight = measureText(
      target.text,
      kpiTextStyle(fit.fontSize),
      width,
    ).height;
    final extra = kpiCommentGap + kpiCommentHeight;
    final need =
        2 + math.max(2 * kpiChipPad + textHeight + extra, kpiChipMinHeight);
    if (need > cardHeight) return null;
    return Padding(
      padding: const EdgeInsets.only(top: kpiCommentGap),
      child: Text(
        commentLine(targetComment(target)!, width),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: _commentStyle,
      ),
    );
  }

  Widget _card(double cardHeight, Color color, String word, Widget text) {
    final comment = _comment(cardHeight);
    return Container(
      decoration: BoxDecoration(
        color: SlidePalette.card,
        border: Border.all(color: SlidePalette.cardBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: kpiChipPad,
          horizontal: 28,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // The chip fills the height of the card, up to kpiChipMaxHeight:
            // on a tall card (1 to 3 targets) it stays a chip, centred.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: kpiChipMaxHeight),
              child: Container(
                alignment: Alignment.center,
                width: kpiChipWidth,
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
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
            ),
            const SizedBox(width: 16),
            Expanded(
              child: comment == null
                  ? text
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [text, comment],
                    ),
            ),
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
