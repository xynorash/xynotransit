import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../domain/period.dart';

/// Pictures in the PPTX have this many times the pixels of the slide in each
/// direction (3840 x 2160). Measured for the 34 slide demo deck: about 10 MB.
const pptxPixelRatio = 2.0;

/// Base name shared by every export: "Xynotransit_Regional_Logistics_Meeting_2026-06-09".
/// With a custom meeting [title] the name follows it.
String deckFileBase(Period period, {DateTime? today, String? title}) {
  final d = period.meetingDate ?? today ?? DateTime.now();
  var slug = _plainLetters(title ?? '')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  if (slug.length > 60) {
    slug = slug.substring(0, 60).replaceAll(RegExp(r'_+$'), '');
  }
  if (slug.isEmpty) slug = 'Xynotransit_Regional_Logistics_Meeting';
  return '${slug}_${Period.dateOnly(d)}';
}

const _plain = {
  'àáâãäåāăą': 'a',
  'çćĉčď': 'c',
  'èéêëēėęěğ': 'e',
  'ìíîïīįı': 'i',
  'ñńňł': 'n',
  'òóôõöøōő': 'o',
  'ùúûüūůűų': 'u',
  'ýÿ': 'y',
  'śšş': 's',
  'źżž': 'z',
  'ř': 'r',
  'ť': 't',
};

/// Accented Latin letters as plain ones, so "Réunion Côte d'Ivoire" gives
/// "Reunion_Cote_d_Ivoire" and not "R_union_C_te_d_Ivoire". Everything else
/// that is not a letter or a digit becomes an underscore later.
String _plainLetters(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    final lower = c.toLowerCase();
    String? hit;
    for (final e in _plain.entries) {
      if (e.key.contains(lower)) {
        hit = e.value;
        break;
      }
    }
    if (hit != null) {
      b.write(c == lower ? hit : hit.toUpperCase());
    } else if (c == 'ß') {
      b.write('ss');
    } else if (c == 'æ') {
      b.write('ae');
    } else if (c == 'Æ') {
      b.write('Ae');
    } else if (c == 'œ') {
      b.write('oe');
    } else if (c == 'Œ') {
      b.write('Oe');
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

/// One landscape page of 1920 x 1080 points per slide, picture full bleed.
Future<Uint8List> buildPdf(
  List<Uint8List> pngs, {
  required String title,
}) async {
  final doc = pw.Document(
    title: title,
    author: 'Xynotransit',
    creator: 'Logistics Report Builder',
  );
  const format = PdfPageFormat(1920, 1080);
  for (final png in pngs) {
    final image = pw.MemoryImage(png);
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) =>
            pw.Image(image, fit: pw.BoxFit.fill, width: 1920, height: 1080),
      ),
    );
  }
  return doc.save();
}

/// "slide-01.png" and so on, zipped, for people who want the raw pictures.
Uint8List buildPngZip(List<Uint8List> pngs, List<String> names) {
  final archive = Archive();
  for (var i = 0; i < pngs.length; i++) {
    archive.addFile(ArchiveFile.bytes(names[i], pngs[i]));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
