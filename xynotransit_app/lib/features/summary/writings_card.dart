import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/enums.dart';
import 'summary_provider.dart';
import 'summary_widgets.dart';

const _collapsedCount = 5;

/// The free text people wrote, grouped by kind, and the comments on targets
/// that were only partly met or missed. Read from the reports already loaded.
class WritingsCard extends ConsumerWidget {
  const WritingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(writingsProvider);
    final sections = [
      for (final k in NoteKind.values)
        _Section(id: k.name, title: k.slideTitle, items: w.notes[k]!),
      _Section(
        id: 'comments',
        title: 'Comments on targets not met',
        items: w.comments,
      ),
    ];
    return ChartCard(
      title: 'What people wrote',
      explain:
          'Notes from every sent report, in the words of the people who '
          'wrote them.',
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final s in sections) ...[
                  _SectionView(section: s),
                  const SizedBox(height: 20),
                ],
              ],
            );
          }
          Widget row(int a, int b) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _SectionView(section: sections[a])),
              const SizedBox(width: 28),
              Expanded(child: _SectionView(section: sections[b])),
            ],
          );
          return Column(
            children: [row(0, 1), const SizedBox(height: 24), row(2, 3)],
          );
        },
      ),
    );
  }
}

class _Section {
  const _Section({required this.id, required this.title, required this.items});
  final String id;
  final String title;
  final List<Written> items;
}

class _SectionView extends StatefulWidget {
  const _SectionView({required this.section});

  final _Section section;

  @override
  State<_SectionView> createState() => _SectionViewState();
}

class _SectionViewState extends State<_SectionView> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = widget.section;
    final items = s.items;
    final shown = _all ? items : items.take(_collapsedCount).toList();
    return Column(
      key: ValueKey('writings-${s.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            '${s.title} (${items.length})',
            style: bodyStyle(context, size: 16, weight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text(
            'Nothing written yet.',
            style: bodyStyle(context, size: 14, color: t.muted),
          ),
        for (final w in shown) _WrittenView(item: w),
        if (items.length > _collapsedCount)
          Align(
            alignment: Alignment.centerLeft,
            child: TextLinkButton(
              label: _all ? 'Show fewer' : 'Show all ${items.length}',
              onPressed: () => setState(() => _all = !_all),
            ),
          ),
      ],
    );
  }
}

class _WrittenView extends StatelessWidget {
  const _WrittenView({required this.item});

  final Written item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: switch (item.status) {
                KpiStatus.missed => t.bad,
                KpiStatus.partly => t.warn,
                _ => t.line,
              },
              width: 3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.target != null)
              Text(
                '${item.status == KpiStatus.missed ? 'Missed' : 'Partly met'}: '
                '${item.target}',
                style: bodyStyle(
                  context,
                  size: 13,
                  color: t.muted,
                  height: 1.3,
                ),
              ),
            Text(item.text, style: bodyStyle(context, size: 15, height: 1.35)),
            Text(
              '${item.author} · ${item.team}',
              style: bodyStyle(context, size: 13, color: t.muted, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }
}
