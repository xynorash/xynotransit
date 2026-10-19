import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/deck_text.dart';
import '../../domain/enums.dart';
import '../../domain/snapshot.dart';
import 'canvas.dart';
import 'icons.dart';
import 'measure.dart';
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
    final colTitles = [for (final c in columns) s.notesOf(c.$1)];
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
      // The notes take the biggest type in which the fullest column fits.
      body: LayoutBuilder(
        builder: (context, box) {
          final noteSize = pickNoteSize([
            for (final n in colTitles) n.isEmpty ? [texts['emptyNote']] : n,
          ], box.maxHeight);
          // The fullest column fills its card; with room to spare every
          // column starts at the same height, so the group sits in the middle
          // of the cards and the first lines stay level across them.
          final tallest = [
            for (final n in colTitles)
              noteColumnHeight(n.isEmpty ? [texts['emptyNote']] : n, noteSize),
          ].reduce(math.max);
          final inset = math.max(0.0, (box.maxHeight - tallest) / 2);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns.length; i++) ...[
                if (i > 0) const SizedBox(width: 32),
                Expanded(
                  child: _NoteColumn(
                    title: titles[i],
                    titleSize: size,
                    noteSize: noteSize,
                    topInset: inset,
                    emptyNote: texts['emptyNote'],
                    icon: columns[i].$2,
                    fill: columns[i].$3,
                    notes: s.notesOf(columns[i].$1),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Width of the text of a note: a third of the text area, minus the gaps and
/// the 40 px padding on both sides.
const _noteWidth = (slideTextWidth - 64) / 3 - 80;

/// Few points get big type so the cards are not mostly empty; the fullest
/// column decides how big it can be.
const _noteSizes = [
  44.0,
  40.0,
  36.0,
  34.0,
  32.0,
  30.0,
  28.0,
  26.0,
  24.0,
  22.0,
  20.0,
];
const _headerHeight = 56 + 52.8;
const _bodyPad = 8 + 24.0;

double _notePad(double size) => (size * 0.6875).roundToDouble();

/// Height a column of [notes] needs at [size].
double noteColumnHeight(List<String> notes, double size) {
  var h = _headerHeight + _bodyPad;
  for (final n in notes) {
    h +=
        measureText(n, st(size, height: 1.3), _noteWidth).height +
        2 * _notePad(size);
  }
  return h;
}

/// The biggest size (44 px down to 20 px) in which every column fits [height].
double pickNoteSize(List<List<String>> columns, double height) {
  for (final z in _noteSizes) {
    if (columns.every((c) => noteColumnHeight(c, z) <= height)) return z;
  }
  return _noteSizes.last;
}

class _NoteColumn extends StatelessWidget {
  const _NoteColumn({
    required this.title,
    required this.titleSize,
    required this.noteSize,
    required this.topInset,
    required this.emptyNote,
    required this.icon,
    required this.fill,
    required this.notes,
  });

  final String title;
  final double titleSize;
  final double noteSize;

  /// Air above the first point, the same in all three columns.
  final double topInset;
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
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(40, 8 + topInset, 40, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      Container(
                        padding: EdgeInsets.symmetric(
                          vertical: _notePad(noteSize),
                        ),
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
                            noteSize,
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
            ),
          ],
        ),
      ),
    );
  }
}
