import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../slides/canvas.dart';

/// Draws a slide off screen at exactly 1920 x 1080 and returns it as a PNG.
Future<Uint8List> slideToPng(BuildContext context, Widget slide) async {
  final key = GlobalKey();
  final overlay = Overlay.of(context, rootOverlay: true);
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -(slideWidth + 200),
      top: 0,
      width: slideWidth,
      height: slideHeight,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: RepaintBoundary(key: key, child: slide),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    // One frame to lay out and paint, one more so fonts and images settle.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
    entry.dispose();
  }
}
