import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Code points of a TrueType font's Unicode cmap (formats 4 and 12).
Set<int> cmapOf(String path) {
  final b = ByteData.sublistView(
    Uint8List.fromList(File(path).readAsBytesSync()),
  );
  final tables = b.getUint16(4);
  var cmapAt = -1;
  for (var i = 0; i < tables; i++) {
    final rec = 12 + i * 16;
    final tag = String.fromCharCodes([
      for (var k = 0; k < 4; k++) b.getUint8(rec + k),
    ]);
    if (tag == 'cmap') cmapAt = b.getUint32(rec + 8);
  }
  expect(cmapAt, greaterThan(0), reason: 'no cmap table in $path');
  final out = <int>{};
  final n = b.getUint16(cmapAt + 2);
  for (var i = 0; i < n; i++) {
    final platform = b.getUint16(cmapAt + 4 + i * 8);
    final enc = b.getUint16(cmapAt + 6 + i * 8);
    if (!((platform == 3 && (enc == 1 || enc == 10)) || platform == 0)) {
      continue;
    }
    final at = cmapAt + b.getUint32(cmapAt + 8 + i * 8);
    final format = b.getUint16(at);
    if (format == 4) {
      final segs = b.getUint16(at + 6) ~/ 2;
      final ends = at + 14;
      final starts = ends + segs * 2 + 2;
      final deltas = starts + segs * 2;
      final ranges = deltas + segs * 2;
      for (var s = 0; s < segs; s++) {
        final end = b.getUint16(ends + s * 2);
        final start = b.getUint16(starts + s * 2);
        final delta = b.getInt16(deltas + s * 2);
        final ro = b.getUint16(ranges + s * 2);
        for (var c = start; c <= end && c != 0xFFFF; c++) {
          var g = 0;
          if (ro == 0) {
            g = (c + delta) & 0xFFFF;
          } else {
            final p = ranges + s * 2 + ro + (c - start) * 2;
            g = b.getUint16(p);
            if (g != 0) g = (g + delta) & 0xFFFF;
          }
          if (g != 0) out.add(c);
        }
      }
    } else if (format == 12) {
      final groups = b.getUint32(at + 12);
      for (var g = 0; g < groups; g++) {
        final o = at + 16 + g * 12;
        for (var c = b.getUint32(o); c <= b.getUint32(o + 4); c++) {
          out.add(c);
        }
      }
    }
  }
  return out;
}

void main() {
  // Letters and signs of Malagasy, French and Mauritian Creole text, and the
  // punctuation the app and the slides print.
  const needed =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
      'ôÔñÑ'
      'àâäÀÂÄ éèêëÉÈÊË îïÎÏ ìÌ òÒ ôÔ ùûüÙÛÜ çÇ œŒ æÆ ÿŸ'
      'áíóúÁÍÓÚ ãõÃÕ'
      '’‘“”«»–—…€°·×•±≥≤→←↑↓%&@#/:;,.!?()[]+-= ';

  for (final f in ['Regular', 'Medium', 'Bold']) {
    test('DM Sans $f has every Malagasy, French and Creole letter', () {
      final cm = cmapOf('assets/fonts/DMSans-$f.ttf');
      final missing = [
        for (final r in needed.runes)
          if (r != 0x20 && !cm.contains(r)) String.fromCharCode(r),
      ];
      expect(missing, isEmpty);
    });
  }

  test('DM Sans has all of Latin-1 and Latin Extended-A used by names', () {
    final cm = cmapOf('assets/fonts/DMSans-Regular.ttf');
    final missing = [
      for (var c = 0xA1; c < 0x180; c++)
        if (!cm.contains(c)) c,
    ];
    // Only the soft hyphen and a few letters of Esperanto, Finnish-Sami and
    // old German are absent. None is used in the three languages.
    expect(missing.map((c) => c.toRadixString(16)).toList(), [
      'ad',
      '108',
      '109',
      '11c',
      '11d',
      '124',
      '125',
      '134',
      '135',
      '138',
      '149',
      '15c',
      '15d',
      '166',
      '167',
      '17f',
    ]);
  });

  test('Plex Mono (numbers) has digits and the thousands comma', () {
    final cm = cmapOf('assets/fonts/IBMPlexMono-Regular.ttf');
    for (final r in '0123456789,.%-/'.runes) {
      expect(cm.contains(r), isTrue, reason: String.fromCharCode(r));
    }
  });
}
