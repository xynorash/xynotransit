import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/widgets.dart';
import '../data/memory_repository.dart';
import '../domain/deck.dart';
import 'slides/alt_text.dart';
import 'slides/slide_view.dart';

/// Hidden route: every slide of the demo deck, for checking the design.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  late final Future<List<SlideSpec>> _slides = _build();

  Future<List<SlideSpec>> _build() async {
    // Not catalogProvider.future: nothing else listens to that provider on
    // this route, so it would never produce a value and the page would wait
    // for ever.
    final catalog = await ref.read(repositoryProvider).loadCatalog();
    final repo = MemoryRepository(
      catalog: catalog,
      currentUser: () => DemoAuth.controller,
      withDemoReports: true,
    );
    final period = await repo.ensurePeriod(MemoryRepository.demoStart);
    final run = await repo.generateDeck(period, catalog);
    return buildDeck(run, repo.periodById(period.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Slide gallery')),
      body: FutureBuilder<List<SlideSpec>>(
        future: _slides,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(
              child: Text('The slides could not be built. Reload the page.'),
            );
          }
          final slides = snap.data;
          if (slides == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 1500 ? 3 : (c.maxWidth >= 900 ? 2 : 1);
              // Each cell is a caption line plus a 16:9 slide.
              final cellWidth = (c.maxWidth - 32 - 16 * (cols - 1)) / cols;
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  mainAxisExtent: cellWidth * 9 / 16 + 34,
                ),
                itemCount: slides.length,
                itemBuilder: (context, i) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${i + 1} of ${slides.length} · ${slideTitle(slides[i])}',
                      style: monoStyle(context, size: 13),
                    ),
                    const SizedBox(height: 6),
                    SlideStage(
                      semanticLabel: slideAltText(slides[i]),
                      child: slideFor(slides[i]),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
