import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/deck.dart';
import '../slides/slide_words.dart';
import '../../domain/period.dart';
import '../export/export_menu.dart';
import '../slides/alt_text.dart';
import '../slides/slide_view.dart';

/// Drives the vertical slide list: jump to a slide and report which one is in view.
class SlideNav {
  final controller = ScrollController();
  final anchorKey = GlobalKey(debugLabel: 'slides-anchor');

  /// Index of the slide nearest the top of the view.
  final current = ValueNotifier<int>(0);

  double extent = 0;
  int count = 0;

  SlideNav() {
    controller.addListener(_track);
  }

  double? _anchorOffset() {
    final ro = anchorKey.currentContext?.findRenderObject();
    if (ro == null) return null;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    return viewport?.getOffsetToReveal(ro, 0).offset;
  }

  void _track() {
    final anchor = _anchorOffset();
    if (anchor == null || extent <= 0 || count == 0 || !controller.hasClients) {
      return;
    }
    // At the very end the last slides cannot reach the top, so the last one counts.
    final atEnd = controller.offset >= controller.position.maxScrollExtent - 1;
    final i = atEnd
        ? count - 1
        : ((controller.offset - anchor) / extent).round();
    final clamped = i.clamp(0, count - 1);
    if (clamped != current.value) current.value = clamped;
  }

  void jumpTo(int i, {bool animate = true}) {
    final anchor = _anchorOffset();
    if (anchor == null || !controller.hasClients) return;
    final max = controller.position.maxScrollExtent;
    final target = (anchor + i * extent).clamp(0.0, max);
    if (animate) {
      unawaited(
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      controller.jumpTo(target);
    }
    current.value = i.clamp(0, count == 0 ? 0 : count - 1);
  }

  void dispose() {
    controller.dispose();
    current.dispose();
  }
}

final slideNavProvider = Provider<SlideNav>((ref) {
  final nav = SlideNav();
  ref.onDispose(nav.dispose);
  return nav;
});

const staleTextNotice =
    'Slide text changed after this deck was generated. Regenerate to apply it.';

/// The card above the slides: title, export, generate controls and the jump menu.
class PreviewHeader extends ConsumerWidget {
  const PreviewHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deck = ref.watch(deckProvider).value;
    final period = ref.watch(periodProvider).value;
    final saved = ref.watch(deckTextsProvider).value?.texts;
    // The slides and exports keep the words they were generated with. Say so
    // when the saved words have moved on.
    final stale =
        deck != null &&
        deck.items.isNotEmpty &&
        saved != null &&
        ref.watch(isControllerProvider) &&
        saved != deck.texts;
    return XCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Slide preview',
                  style: bodyStyle(
                    context,
                    size: 20,
                    weight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              if (deck != null &&
                  ref.watch(isControllerProvider) &&
                  period != null)
                ExportMenu(run: deck, period: period),
              Text(
                deck == null
                    ? 'Not generated yet'
                    : 'Generated ${shortDateTime(deck.generatedAt)}',
                style: monoStyle(context, size: 15),
              ),
            ],
          ),
          if (deck != null && deck.items.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              SlideWords(deck.texts)
                  .title(deck.items.first.snapshot.periodLabel),
              key: const ValueKey('deck-title'),
              style: bodyStyle(context, size: 16, weight: FontWeight.w500),
            ),
          ],
          const SizedBox(height: 12),
          if (stale) ...[
            SoftBanner(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  staleTextNotice,
                  key: const ValueKey('stale-notice'),
                  style: bodyStyle(context, size: 15, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          const GenerateControls(),
          if (deck != null && deck.items.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Navigator(run: deck, period: period),
          ],
        ],
      ),
    );
  }
}

class GenerateControls extends ConsumerStatefulWidget {
  const GenerateControls({super.key});

  @override
  ConsumerState<GenerateControls> createState() => _GenerateControlsState();
}

class _GenerateControlsState extends ConsumerState<GenerateControls> {
  bool _confirm = false;
  bool _busy = false;
  String? _error;

  Future<void> _generate() async {
    final period = ref.read(periodProvider).value;
    final catalog = ref.read(catalogProvider).value;
    if (period == null || catalog == null) return;
    setState(() {
      _busy = true;
      _confirm = false;
      _error = null;
    });
    try {
      await ref.read(repositoryProvider).generateDeck(period, catalog);
      final nav = ref.read(slideNavProvider);
      if (nav.controller.hasClients) nav.jumpTo(0, animate: false);
    } on Object {
      if (mounted) {
        setState(
          () => _error = 'Could not generate. Only the controller can do this.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final catalog = ref.watch(catalogProvider).value;
    final period = ref.watch(periodProvider).value;
    final reports = ref.watch(reportsProvider).value ?? const [];
    final deck = ref.watch(deckProvider).value;
    final isController = ref.watch(isControllerProvider);
    if (catalog == null || period == null) return const SizedBox.shrink();
    final n = reports.where((r) => r.isSubmitted).length;
    final total = catalog.assignments.length;
    final hint = '$n of $total reports in for ${period.label}';

    if (!isController) {
      return Text(
        'The controller generates the slides when everyone is done. $hint.',
        style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          runSpacing: 8,
          children: [
            PrimaryButton(
              label: _busy
                  ? 'Generating…'
                  : (deck == null ? 'Generate slides' : 'Regenerate slides'),
              onPressed: _busy || n == 0
                  ? null
                  : () {
                      if (n < total) {
                        setState(() => _confirm = true);
                      } else {
                        unawaited(_generate());
                      }
                    },
            ),
            Text(
              hint,
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
            ),
            MeetingDateButton(period: period),
          ],
        ),
        if (_confirm) ...[
          const SizedBox(height: 12),
          SoftBanner(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Only $n of $total reports are in. Generate the slides with what you have?',
                  style: bodyStyle(context, size: 15, height: 1.4),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PrimaryButton(
                      label: 'Generate anyway',
                      onPressed: () => unawaited(_generate()),
                    ),
                    GhostButton(
                      label: 'Wait',
                      onPressed: () => setState(() => _confirm = false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: bodyStyle(context, size: 15, color: t.bad, height: 1.4),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shows the meeting date of [period] and lets the controller change it.
class MeetingDateButton extends ConsumerWidget {
  const MeetingDateButton({super.key, required this.period});

  final Period period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = period.meetingDate;
    return TextLinkButton(
      label: date == null
          ? 'Set meeting date'
          : 'Meeting ${shortDate(date)} ${date.year}',
      semanticLabel: date == null
          ? 'Set meeting date'
          : 'Change meeting date, now ${longDate(date)}',
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date ?? DateTime.now(),
          firstDate: DateTime(2024),
          lastDate: DateTime(2100),
        );
        if (picked == null) return;
        try {
          await ref.read(repositoryProvider).setMeetingDate(period.id, picked);
          ref.invalidate(periodProvider);
        } on RepositoryException catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(e.message)));
          }
        }
      },
    );
  }
}

class _Navigator extends ConsumerWidget {
  const _Navigator({required this.run, required this.period});

  final DeckRun run;
  final Period? period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slides = buildDeck(run, period);
    final nav = ref.watch(slideNavProvider);
    nav.count = slides.length;
    return ValueListenableBuilder<int>(
      valueListenable: nav.current,
      builder: (context, current, _) {
        final index = current.clamp(0, slides.length - 1);
        void go(int i) => nav.jumpTo((i + slides.length) % slides.length);
        return Row(
          children: [
            SizedBox(
              width: 52,
              child: GhostButton(
                label: '‹',
                semanticLabel: 'Previous slide',
                onPressed: () => go(index - 1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey('nav-$index-${slides.length}'),
                initialValue: index,
                isExpanded: true,
                decoration: xInput(context),
                items: [
                  for (var i = 0; i < slides.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i + 1} · ${slideTitle(slides[i])}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (i) {
                  if (i != null) go(i);
                },
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: GhostButton(
                label: '›',
                semanticLabel: 'Next slide',
                onPressed: () => go(index + 1),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Every slide of the deck in order, one under the other. Lazy: only the slides
/// near the screen are built. Place inside a [CustomScrollView] that uses
/// [SlideNav.controller] and tell it the width the slides get.
class SlideListSliver extends ConsumerWidget {
  const SlideListSliver({super.key, required this.width});

  final double width;

  /// Caption line, border and the gap under each slide.
  static const _chrome = 44.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final deck = ref.watch(deckProvider).value;
    final period = ref.watch(periodProvider).value;
    final nav = ref.watch(slideNavProvider);
    if (deck == null || deck.items.isEmpty) {
      return SliverToBoxAdapter(
        key: nav.anchorKey,
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: DashedBox(
            child: Text(
              'No slides yet. When the controller generates them, every slide of the deck '
              'appears here in order, exactly as it will be presented.',
              textAlign: TextAlign.center,
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
            ),
          ),
        ),
      );
    }
    final slides = buildDeck(deck, period);
    final extent = width * 9 / 16 + _chrome;
    nav
      ..extent = extent
      ..count = slides.length;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          key: nav.anchorKey,
          child: const SizedBox(height: 16),
        ),
        SliverFixedExtentList.builder(
          itemExtent: extent,
          itemCount: slides.length,
          itemBuilder: (context, i) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6, top: 2),
                child: Text(
                  'Slide ${i + 1} of ${slides.length} · ${slideTitle(slides[i])}',
                  style: monoStyle(context, size: 13),
                  textScaler: TextScaler.noScaling,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SlideStage(
                semanticLabel: slideAltText(slides[i]),
                child: slideFor(slides[i]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
