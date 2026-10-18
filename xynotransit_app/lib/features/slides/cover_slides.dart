import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import 'canvas.dart';
import 'palette.dart';
import 'slide_words.dart';

Widget _pill(String text, Color fill, Color ink) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: slideTextWidth),
  child: Container(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 28),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: st(32, weight: FontWeight.w500, color: ink),
    ),
  ),
);

const _coverSteps = <FitStep>[
  (120, 2),
  (100, 3),
  (84, 3),
  (72, 3),
  (60, 3),
  (52, 3),
];

const _dividerSteps = <FitStep>[(140, 2), (110, 2), (90, 3), (72, 3), (60, 3)];

const _dateSteps = <FitStep>[(24, 1), (22, 1), (20, 1), (18, 1)];

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

  static const _subSteps = <FitStep>[(44, 1), (40, 2), (36, 2), (32, 2)];

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
    final date = w.dateLine(meetingDate);
    final dateFit = pickFit(
      date,
      slideTextWidth,
      _dateSteps,
      (z) => st(z, weight: FontWeight.w700, letterSpacing: z / 8),
    );
    return SlideCanvas(
      background: SlidePalette.navy,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(128, 128, 128, 160),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: st(
                dateFit.$1,
                weight: FontWeight.w700,
                color: SlidePalette.orange,
                letterSpacing: dateFit.$1 / 8,
              ),
            ),
            _TitleBlock(
              title: w.title(periodLabel),
              titleColor: SlidePalette.paper,
              titleSteps: _coverSteps,
              titleHeight: 1.05,
              subtitle: w.subtitle(periodLabel),
              subtitleColor: SlidePalette.panelText,
            ),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final (team, n) in teamCounts)
                  _pill(
                    w.coverPill(team, n),
                    SlidePalette.paper,
                    SlidePalette.navy,
                  ),
              ],
            ),
          ],
        ),
      ),
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
    final eyebrow = w
        .dividerEyebrow(team, index, total, k, periodLabel)
        .toUpperCase();
    final eyebrowFit = pickFit(
      eyebrow,
      slideTextWidth,
      _dateSteps,
      (z) => st(z, weight: FontWeight.w700, letterSpacing: z / 8),
    );
    return SlideCanvas(
      background: SlidePalette.blue,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(128, 128, 128, 160),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              eyebrow,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: st(
                eyebrowFit.$1,
                weight: FontWeight.w700,
                color: SlidePalette.white,
                letterSpacing: eyebrowFit.$1 / 8,
              ),
            ),
            _TitleBlock(
              title: w.dividerTitle(team),
              titleColor: SlidePalette.white,
              titleSteps: _dividerSteps,
              titleHeight: 1.05,
              subtitle: w.dividerSubtitle(team, k),
              subtitleColor: SlidePalette.white,
            ),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final p in people)
                  _pill(p, SlidePalette.white, SlidePalette.navy),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
