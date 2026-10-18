import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One slide of the exported deck: a full-bleed picture plus words for people
/// who cannot see it.
class PptxSlide {
  const PptxSlide({
    required this.png,
    required this.altText,
    required this.notes,
  });
  final Uint8List png;
  final String altText;
  final String notes;
}

const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _relNs = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _relType =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _ctPrefix =
    'application/vnd.openxmlformats-officedocument.presentationml';

/// 16:9 at 12192000 x 6858000 EMU, the PowerPoint widescreen size.
const slideCx = 12192000;
const slideCy = 6858000;

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

String _rels(List<(String id, String type, String target)> items) =>
    '$_xmlHead<Relationships xmlns="$_relNs">'
    '${items.map((r) => '<Relationship Id="${r.$1}" Type="$_relType/${r.$2}" Target="${r.$3}"/>').join()}'
    '</Relationships>';

const _grp =
    '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
    '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>';

const _clrMap =
    '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" '
    'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>';

String _theme(String name) {
  String clr(String tag, String hex) =>
      '<a:$tag><a:srgbClr val="$hex"/></a:$tag>';
  const fill = '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>';
  const ln =
      '<a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:prstDash val="solid"/></a:ln>';
  const font =
      '<a:latin typeface="DM Sans"/><a:ea typeface=""/><a:cs typeface=""/>';
  return '$_xmlHead<a:theme xmlns:a="$_nsA" name="${_esc(name)}"><a:themeElements>'
      '<a:clrScheme name="${_esc(name)}">'
      '${clr('dk1', '14213D')}${clr('lt1', 'FFFFFF')}${clr('dk2', '14213D')}${clr('lt2', 'F4F1EA')}'
      '${clr('accent1', '1D5FD1')}${clr('accent2', 'F0933A')}${clr('accent3', '17785F')}'
      '${clr('accent4', 'B8400A')}${clr('accent5', '6FB1FF')}${clr('accent6', '5FD3B0')}'
      '${clr('hlink', '1D5FD1')}${clr('folHlink', '566175')}'
      '</a:clrScheme>'
      '<a:fontScheme name="${_esc(name)}"><a:majorFont>$font</a:majorFont><a:minorFont>$font</a:minorFont></a:fontScheme>'
      '<a:fmtScheme name="${_esc(name)}">'
      '<a:fillStyleLst>$fill$fill$fill</a:fillStyleLst>'
      '<a:lnStyleLst>$ln$ln$ln</a:lnStyleLst>'
      '<a:effectStyleLst>${'<a:effectStyle><a:effectLst/></a:effectStyle>' * 3}</a:effectStyleLst>'
      '<a:bgFillStyleLst>$fill$fill$fill</a:bgFillStyleLst>'
      '</a:fmtScheme></a:themeElements></a:theme>';
}

String _slideXml(int n, PptxSlide s) =>
    '$_xmlHead<p:sld xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>$_grp'
    '<p:pic><p:nvPicPr><p:cNvPr id="2" name="Slide $n" descr="${_esc(s.altText)}"/>'
    '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
    '<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
    '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$slideCx" cy="$slideCy"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>'
    '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>';

String _notesXml(String text) =>
    '$_xmlHead<p:notes xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>$_grp'
    '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr>'
    '<p:spPr/></p:sp>'
    '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>'
    '<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>${_esc(text)}</a:t></a:r></a:p></p:txBody></p:sp>'
    '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>';

const _notesMaster =
    '$_xmlHead<p:notesMaster xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>$_grp'
    '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="3086100"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:sp>'
    '<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/>'
    '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="685800" y="4400550"/><a:ext cx="5486400" cy="3600450"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
    '<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>'
    '</p:spTree></p:cSld>$_clrMap</p:notesMaster>';

const _master =
    '$_xmlHead<p:sldMaster xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld>'
    '<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>$_grp</p:spTree></p:cSld>'
    '$_clrMap<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>';

const _layout =
    '$_xmlHead<p:sldLayout xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP" type="blank" preserve="1">'
    '<p:cSld name="Blank"><p:spTree>$_grp</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>';

/// Builds a .pptx whose slides are full-bleed pictures with alt text and speaker notes.
Uint8List buildPptx(List<PptxSlide> slides, {String title = 'Xynotransit'}) {
  final files = <String, List<int>>{};
  void put(String name, String xml) => files[name] = utf8.encode(xml);

  final n = slides.length;
  final overrides = StringBuffer()
    ..write(
      '<Override PartName="/ppt/presentation.xml" ContentType="$_ctPrefix.presentation.main+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="$_ctPrefix.slideMaster+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="$_ctPrefix.slideLayout+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="$_ctPrefix.notesMaster+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
    )
    ..write(
      '<Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>',
    );
  for (var i = 1; i <= n; i++) {
    overrides
      ..write(
        '<Override PartName="/ppt/slides/slide$i.xml" ContentType="$_ctPrefix.slide+xml"/>',
      )
      ..write(
        '<Override PartName="/ppt/notesSlides/notesSlide$i.xml" ContentType="$_ctPrefix.notesSlide+xml"/>',
      );
  }
  put(
    '[Content_Types].xml',
    '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>$overrides</Types>',
  );
  put(
    '_rels/.rels',
    _rels([('rId1', 'officeDocument', 'ppt/presentation.xml')]),
  );

  final sldIds = StringBuffer();
  final presRels = <(String, String, String)>[
    ('rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'),
    ('rId2', 'notesMaster', 'notesMasters/notesMaster1.xml'),
    ('rId3', 'theme', 'theme/theme1.xml'),
  ];
  for (var i = 1; i <= n; i++) {
    sldIds.write('<p:sldId id="${255 + i}" r:id="rId${3 + i}"/>');
    presRels.add(('rId${3 + i}', 'slide', 'slides/slide$i.xml'));
  }
  put(
    'ppt/presentation.xml',
    '$_xmlHead<p:presentation xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP">'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst>'
        '<p:sldIdLst>$sldIds</p:sldIdLst>'
        '<p:sldSz cx="$slideCx" cy="$slideCy"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
  );
  put('ppt/_rels/presentation.xml.rels', _rels(presRels));
  put('ppt/slideMasters/slideMaster1.xml', _master);
  put(
    'ppt/slideMasters/_rels/slideMaster1.xml.rels',
    _rels([
      ('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
      ('rId2', 'theme', '../theme/theme1.xml'),
    ]),
  );
  put('ppt/slideLayouts/slideLayout1.xml', _layout);
  put(
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
    _rels([('rId1', 'slideMaster', '../slideMasters/slideMaster1.xml')]),
  );
  put('ppt/notesMasters/notesMaster1.xml', _notesMaster);
  put(
    'ppt/notesMasters/_rels/notesMaster1.xml.rels',
    _rels([('rId1', 'theme', '../theme/theme2.xml')]),
  );
  put('ppt/theme/theme1.xml', _theme(title));
  put('ppt/theme/theme2.xml', _theme('$title notes'));

  for (var i = 1; i <= n; i++) {
    final s = slides[i - 1];
    put('ppt/slides/slide$i.xml', _slideXml(i, s));
    put(
      'ppt/slides/_rels/slide$i.xml.rels',
      _rels([
        ('rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'),
        ('rId2', 'image', '../media/image$i.png'),
        ('rId3', 'notesSlide', '../notesSlides/notesSlide$i.xml'),
      ]),
    );
    put('ppt/notesSlides/notesSlide$i.xml', _notesXml(s.notes));
    put(
      'ppt/notesSlides/_rels/notesSlide$i.xml.rels',
      _rels([
        ('rId1', 'notesMaster', '../notesMasters/notesMaster1.xml'),
        ('rId2', 'slide', '../slides/slide$i.xml'),
      ]),
    );
    files['ppt/media/image$i.png'] = s.png;
  }

  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
