import 'dart:async';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/deck.dart';
import '../../domain/period.dart';
import 'deck_export.dart';
import 'deck_render.dart';
import 'pptx.dart';

enum _Format { pdf, pptx, png }

/// Controller-only menu: PDF, PPTX or one PNG per slide (zipped).
class ExportMenu extends StatefulWidget {
  const ExportMenu({super.key, required this.run, required this.period});

  final DeckRun run;
  final Period period;

  @override
  State<ExportMenu> createState() => _ExportMenuState();
}

class _ExportMenuState extends State<ExportMenu> {
  String? _progress;

  /// 0..1 while slides are drawn, null when the length is not known.
  double? _fraction;

  /// True from the first click until the export is over, so a second click
  /// cannot start another one.
  bool _busy = false;

  Future<void> _export(_Format format) async {
    if (_busy) return;
    _busy = true;
    final slides = buildDeck(widget.run, widget.period);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pngs = await renderDeckPngs(
        context,
        slides,
        isActive: () => mounted,
        onProgress: (i, n) {
          if (mounted) {
            setState(() {
              _progress = 'Exporting slide ${i + 1} of $n…';
              _fraction = (i + 1) / n;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _progress = 'Saving…';
        _fraction = null;
      });
      final base = deckFileBase(widget.period, title: meetingTitleOf(slides));
      switch (format) {
        case _Format.pdf:
          final bytes = await buildPdf(pngs, title: deckTitleOf(slides));
          await _save(base, 'pdf', MimeType.pdf, bytes);
        case _Format.pptx:
          final bytes = buildPptx(
            pptxSlidesFor(slides, pngs),
            title: deckTitleOf(slides),
          );
          await _save(base, 'pptx', MimeType.microsoftPresentation, bytes);
        case _Format.png:
          await _save(
            base,
            'zip',
            MimeType.zip,
            buildPngZip(pngs, pngNames(pngs.length)),
          );
      }
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export the slides. $e')),
      );
    } finally {
      _busy = false;
      if (mounted) {
        setState(() {
          _progress = null;
          _fraction = null;
        });
      }
    }
  }

  Future<void> _save(
    String name,
    String ext,
    MimeType mime,
    Uint8List bytes,
  ) async {
    // Web downloads straight away; mobile and desktop ask where to save.
    if (kIsWeb) {
      await FileSaver.instance.saveFile(
        name: name,
        bytes: bytes,
        fileExtension: ext,
        mimeType: mime,
      );
    } else {
      await FileSaver.instance.saveAs(
        name: name,
        bytes: bytes,
        fileExtension: ext,
        mimeType: mime,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (_progress != null) {
      return Semantics(
        liveRegion: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _progress!,
                style: monoStyle(context, size: 16, color: t.ink),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  key: const ValueKey('export-progress'),
                  value: _fraction,
                  minHeight: 8,
                  color: t.accent,
                  backgroundColor: t.soft,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return PopupMenuButton<_Format>(
      tooltip: 'Export the slides',
      onSelected: _busy ? null : (f) => unawaited(_export(f)),
      itemBuilder: (_) => const [
        PopupMenuItem(value: _Format.pdf, child: Text('PDF')),
        PopupMenuItem(value: _Format.pptx, child: Text('PowerPoint (PPTX)')),
        PopupMenuItem(
          value: _Format.png,
          child: Text('One PNG per slide (ZIP)'),
        ),
      ],
      // No alignment here: it would stretch the button across a Wrap line.
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: t.soft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'Export',
          style: bodyStyle(
            context,
            size: 15,
            weight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}
