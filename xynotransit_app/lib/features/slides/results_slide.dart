import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import '../../domain/enums.dart';
import '../../domain/snapshot.dart';
import 'canvas.dart';
import 'icons.dart';
import 'palette.dart';
import 'slide_words.dart';

const _titleSteps = <FitStep>[
  (44, 1),
  (40, 1),
  (36, 1),
  (32, 1),
  (28, 1),
  (24, 1),
  (22, 2),
];

// Column 533.3 wide, minus 2 x 40 padding, the 48 px icon and its 16 px gap.
const _titleWidth = (slideTextWidth - 64) / 3 - 80 - 64;

TextStyle _titleStyle(double size) => st(
  size,
  weight: FontWeight.w700,
  color: SlidePalette.white,
  // The title always takes 52.8 px (one line, or two small ones), so the
  // three headers stay level.
  height: 44 * 1.2 / (size < 24 ? 2 : 1) / size,
);

/// Slide 2 of 2: highlights, lowlights and priorities.
class SlideResults extends StatelessWidget {
  const SlideResults(this.snapshot, {super.key, this.texts = DeckTexts.empty});

  final ReportSnapshot snapshot;
  final DeckTexts texts;

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final w = SlideWords(texts);
    final columns = [
      (NoteKind.well, NoteIcon.check, SlidePalette.green),
      (NoteKind.wrong, NoteIcon.warning, SlidePalette.rust),
      (NoteKind.next, NoteIcon.bulb, SlidePalette.blue),
    ];
    final titles = [
      texts['highlightsTitle'],
      texts['lowlightsTitle'],
      texts['nextTitle'],
    ];
    // The three titles share one size so the columns stay level.
    final size = titles
        .map((t) => pickFit(t, _titleWidth, _titleSteps, _titleStyle).$1)
        .reduce(math.min);
    return PersonSlideFrame(
      background: SlidePalette.navy,
      footerColor: SlidePalette.mutedOnDark,
      source: w.footer(s),
      page: '2 / 2',
      heading: SlideHeading(
        eyebrow: w.resultsEyebrow(s),
        title: w.resultsTitle(s),
        eyebrowColor: SlidePalette.orange,
        titleColor: SlidePalette.paper,
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < columns.length; i++) ...[
            if (i > 0) const SizedBox(width: 32),
            Expanded(
              child: _NoteColumn(
                title: titles[i],
                titleSize: size,
                emptyNote: texts['emptyNote'],
                icon: columns[i].$2,
                fill: columns[i].$3,
                notes: s.notesOf(columns[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoteColumn extends StatelessWidget {
  const _NoteColumn({
    required this.title,
    required this.titleSize,
    required this.emptyNote,
    required this.icon,
    required this.fill,
    required this.notes,
  });

  final String title;
  final double titleSize;
  final String emptyNote;
  final NoteIcon icon;
  final Color fill;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final rows = notes.isEmpty ? [emptyNote] : notes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: ColoredBox(
        color: SlidePalette.paper,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: fill,
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 40),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CustomPaint(
                    size: const Size(48, 48),
                    painter: NoteIconPainter(icon, SlidePalette.white),
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: _titleStyle(titleSize),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 22),
                      decoration: BoxDecoration(
                        border: i == 0
                            ? null
                            : const Border(
                                top: BorderSide(color: SlidePalette.noteRule),
                              ),
                      ),
                      child: Text(
                        rows[i],
                        style: st(
                          32,
                          height: 1.3,
                          color: notes.isEmpty
                              ? SlidePalette.emptyNote
                              : SlidePalette.ink,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
