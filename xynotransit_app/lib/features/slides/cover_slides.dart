import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import 'canvas.dart';
import 'measure.dart';
import 'palette.dart';
import 'pills.dart';
import 'slide_words.dart';

const _coverSteps = <FitStep>[
  (120, 2),
  (100, 3),
  (84, 3),
  (72, 3),
  (60, 3),
  (52, 3),
];

const _dividerSteps = <FitStep>[(140, 2), (110, 2), (90, 3), (72, 3), (60, 3)];

const _dateSteps = smallLineSteps;

/// Big title, then the line under it. Both shrink and wrap to fit.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({
    required this.title,
    required this.titleColor,
    required this.titleSteps,
    required this.titleHeight,
    required this.subtitle,
    required this.subtitleColor,
  });

  final String title;
  final Color titleColor;
  final List<FitStep> titleSteps;
  final double titleHeight;
  final String subtitle;
  final Color subtitleColor;

  static const _subSteps = <FitStep>[
    (44, 1),
    (40, 2),
    (36, 2),
    (32, 2),
    (28, 3),
    (24, 3),
  ];

  /// Height of the block, for the room left to the pills.
  static double heightOf(
    String title,
    List<FitStep> titleSteps,
    double titleHeight,
    String subtitle,
  ) {
    final t = pickFit(
      title,
      slideTextWidth,
      titleSteps,
      (z) => st(z, weight: FontWeight.w700, height: titleHeight),
    );
    final u = pickFit(subtitle, slideTextWidth, _subSteps, (z) => st(z));
    return _textHeight(
          title,
          st(t.$1, weight: FontWeight.w700, height: titleHeight),
          t.$2,
        ) +
        24 +
        _textHeight(subtitle, st(u.$1), u.$2);
  }

  @override
  Widget build(BuildContext context) {
    TextStyle ts(double size) => st(
      size,
      weight: FontWeight.w700,
      color: titleColor,
      height: titleHeight,
    );
    TextStyle ss(double size) => st(size, color: subtitleColor);
    final t = pickFit(title, slideTextWidth, titleSteps, ts);
    final u = pickFit(subtitle, slideTextWidth, _subSteps, ss);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: t.$2,
          overflow: TextOverflow.ellipsis,
          style: ts(t.$1),
        ),
        const SizedBox(height: 24),
        Text(
          subtitle,
          maxLines: u.$2,
          overflow: TextOverflow.ellipsis,
          style: ss(u.$1),
        ),
      ],
    );
  }
}

double _textHeight(String text, TextStyle style, int lines) =>
    measureText(text, style, slideTextWidth, maxLines: lines).height;

/// Room left for the pills once the small line and the title block are placed
/// in the 792 px high text area, keeping 40 px of air above and below the title.
double _pillRoom(double small, double block) => 792 - small - block - 80;

/// Cover and dividers share one build: a small line, the title block and the
/// pills. The pills get the room the other two leave, so nothing overlaps.
class _PillSlide extends StatelessWidget {
  const _PillSlide({
    required this.background,
    required this.small,
    required this.smallColor,
    required this.title,
    required this.titleColor,
    required this.titleSteps,
    required this.subtitle,
    required this.subtitleColor,
    required this.pills,
    required this.pillFill,
    required this.pillInk,
  });

  final Color background;
  final String small;
  final Color smallColor;
  final String title;
  final Color titleColor;
  final List<FitStep> titleSteps;
  final String subtitle;
  final Color subtitleColor;
  final List<String> pills;
  final Color pillFill;
  final Color pillInk;

  @override
  Widget build(BuildContext context) {
    TextStyle smallStyle(double z) =>
        st(z, weight: FontWeight.w700, color: smallColor, letterSpacing: z / 8);
    final smallFit = pickFit(small, slideTextWidth, _dateSteps, smallStyle);
    final smallH = _textHeight(small, smallStyle(smallFit.$1), smallFit.$2);
    final block = _TitleBlock.heightOf(title, titleSteps, 1.05, subtitle);
    final plan = planPills(pills, maxHeight: _pillRoom(smallH, block));
    return SlideCanvas(
      background: background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(128, 128, 128, 160),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              small,
              maxLines: smallFit.$2,
              overflow: TextOverflow.ellipsis,
              style: smallStyle(smallFit.$1),
            ),
            _TitleBlock(
              title: title,
              titleColor: titleColor,
              titleSteps: titleSteps,
              titleHeight: 1.05,
              subtitle: subtitle,
              subtitleColor: subtitleColor,
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: PillWrap(plan: plan, fill: pillFill, ink: pillInk),
            ),
          ],
        ),
      ),
    );
  }
}

class SlideCover extends StatelessWidget {
  const SlideCover({
    super.key,
    required this.periodLabel,
    required this.meetingDate,
    required this.teamCounts,
    this.texts = DeckTexts.empty,
  });

  final DeckTexts texts;
  final String periodLabel;
  final DateTime? meetingDate;
  final List<(String, int)> teamCounts;

  @override
  Widget build(BuildContext context) {
    final w = SlideWords(texts);
    return _PillSlide(
      background: SlidePalette.navy,
      small: w.dateLine(meetingDate),
      smallColor: SlidePalette.orange,
      title: w.title(periodLabel),
      titleColor: SlidePalette.paper,
      titleSteps: _coverSteps,
      subtitle: w.subtitle(periodLabel),
      subtitleColor: SlidePalette.panelText,
      pills: [for (final (team, n) in teamCounts) w.coverPill(team, n)],
      pillFill: SlidePalette.paper,
      pillInk: SlidePalette.navy,
    );
  }
}

class SlideDivider extends StatelessWidget {
  const SlideDivider({
    super.key,
    required this.team,
    required this.index,
    required this.total,
    required this.people,
    this.periodLabel = '',
    this.texts = DeckTexts.empty,
  });

  final DeckTexts texts;
  final String periodLabel;

  final String team;
  final int index;
  final int total;
  final List<String> people;

  @override
  Widget build(BuildContext context) {
    final k = people.length;
    final w = SlideWords(texts);
    return _PillSlide(
      background: SlidePalette.blue,
      small: w.dividerEyebrow(team, index, total, k, periodLabel).toUpperCase(),
      smallColor: SlidePalette.white,
      title: w.dividerTitle(team),
      titleColor: SlidePalette.white,
      titleSteps: _dividerSteps,
      subtitle: w.dividerSubtitle(team, k),
      subtitleColor: SlidePalette.white,
      pills: people,
      pillFill: SlidePalette.white,
      pillInk: SlidePalette.navy,
    );
  }
}
