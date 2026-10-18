import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'slide_words.dart';

const slideWidth = 1920.0;
const slideHeight = 1080.0;

/// Slide text style. CSS style half-leading, no text scaling, no underline.
TextStyle st(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = const Color(0xFF14213D),
  double height = 1.4,
  double letterSpacing = 0,
}) => TextStyle(
  fontFamily: XynoTokens.sans,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: height,
  letterSpacing: letterSpacing,
  decoration: TextDecoration.none,
  leadingDistribution: TextLeadingDistribution.even,
);

/// A 1920 x 1080 page. Pure widget: no providers, no theme lookups.
class SlideCanvas extends StatelessWidget {
  const SlideCanvas({super.key, required this.background, required this.child});

  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withNoTextScaling(
      child: DefaultTextStyle(
        style: st(32),
        child: SizedBox(
          width: slideWidth,
          height: slideHeight,
          child: ClipRect(
            child: ColoredBox(color: background, child: child),
          ),
        ),
      ),
    );
  }
}

/// Width of the text area of a slide (1920 minus the 128 px margins).
const slideTextWidth = slideWidth - 256;

const _titleSteps = <FitStep>[
  (72, 1),
  (64, 1),
  (56, 1),
  (48, 1),
  (40, 2),
  (36, 2),
  (32, 2),
];
const _eyebrowSteps = <FitStep>[(24, 1), (22, 1), (20, 1), (18, 1), (16, 1)];
const _footerSteps = <FitStep>[(24, 1), (22, 1), (20, 1), (18, 1), (16, 1)];

TextStyle _eyebrowStyle(double size, Color color) =>
    st(size, weight: FontWeight.w700, color: color, letterSpacing: size / 8);

/// Eyebrow and title at the top of a person slide. Long words shrink and wrap
/// to fit [maxWidth]; they never run out of the slide.
class SlideHeading extends StatelessWidget {
  const SlideHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.eyebrowColor,
    required this.titleColor,
    this.maxWidth = slideTextWidth,
  });

  final String eyebrow;
  final String title;
  final Color eyebrowColor;
  final Color titleColor;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final upper = eyebrow.toUpperCase();
    final e = pickFit(
      upper,
      maxWidth,
      _eyebrowSteps,
      (s) => _eyebrowStyle(s, eyebrowColor),
    );
    TextStyle titleStyle(double size) =>
        st(size, weight: FontWeight.w700, color: titleColor, height: 1.1);
    final t = pickFit(title, maxWidth, _titleSteps, titleStyle);
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: maxWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              upper,
              maxLines: e.$2,
              overflow: TextOverflow.ellipsis,
              style: _eyebrowStyle(e.$1, eyebrowColor),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: t.$2,
              overflow: TextOverflow.ellipsis,
              style: titleStyle(t.$1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Frame of a person slide: padding, heading, body, footer and page number.
class PersonSlideFrame extends StatelessWidget {
  const PersonSlideFrame({
    super.key,
    required this.background,
    required this.heading,
    required this.body,
    required this.source,
    this.page,
    required this.footerColor,
    this.badge,
  });

  final Color background;
  final Widget heading;
  final Widget body;
  final String source;

  /// Null for a page without a number.
  final String? page;
  final Color footerColor;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return SlideCanvas(
      background: background,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(128, 128, 128, 160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                const SizedBox(height: 40),
                Expanded(child: body),
              ],
            ),
          ),
          if (badge != null)
            Positioned(right: 128, top: 152, width: 420, child: badge!),
          Positioned(left: 128, bottom: 64, width: 1400, child: _footerText()),
          if (page != null)
            Positioned(
              right: 128,
              bottom: 64,
              width: 120,
              child: Text(
                page!,
                textAlign: TextAlign.right,
                style: st(24, color: footerColor),
              ),
            ),
        ],
      ),
    );
  }

  Widget _footerText() {
    final f = pickFit(
      source,
      1400,
      _footerSteps,
      (s) => st(s, color: footerColor),
    );
    return Text(
      source,
      maxLines: f.$2,
      overflow: TextOverflow.ellipsis,
      style: st(f.$1, color: footerColor),
    );
  }
}
