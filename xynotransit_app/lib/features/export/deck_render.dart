import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../domain/deck.dart';
import '../slides/alt_text.dart';
import '../slides/slide_view.dart';
import '../slides/slide_words.dart';
import 'pptx.dart';
import 'rasterizer.dart';

/// Every export starts here: the same specs and the same widget function
/// (slideFor) as the preview, drawn one by one at 1920 x 1080.
Future<List<Uint8List>> renderDeckPngs(
  BuildContext context,
  List<SlideSpec> specs, {
  bool Function()? isActive,
  void Function(int done, int total)? onProgress,
}) async {
  final pngs = <Uint8List>[];
  for (var i = 0; i < specs.length; i++) {
    if (isActive != null && !isActive()) break;
    onProgress?.call(i, specs.length);
    pngs.add(await slideToPng(context, slideFor(specs[i])));
  }
  return pngs;
}

/// PPTX pages: picture, alt text and speaker notes from the same words.
List<PptxSlide> pptxSlidesFor(List<SlideSpec> specs, List<Uint8List> pngs) => [
  for (var i = 0; i < specs.length; i++)
    PptxSlide(
      png: pngs[i],
      altText: slideAltText(specs[i]),
      notes: slideAltText(specs[i]),
    ),
];

/// "slide-01.png" and so on.
List<String> pngNames(int count) => [
  for (var i = 0; i < count; i++)
    'slide-${(i + 1).toString().padLeft(2, '0')}.png',
];

/// The meeting title of the deck in its own words, with the period:
/// "Xynotransit Regional Logistics Meeting, Feb to Apr 2026".
String deckTitleOf(List<SlideSpec> specs) {
  for (final s in specs) {
    if (s is CoverSpec) {
      return '${SlideWords(s.texts).title(s.periodLabel)}, ${s.periodLabel}';
    }
  }
  return 'Xynotransit';
}

/// Only the meeting title, for file names.
String meetingTitleOf(List<SlideSpec> specs) {
  for (final s in specs) {
    if (s is CoverSpec) return SlideWords(s.texts).title(s.periodLabel);
  }
  return '';
}
