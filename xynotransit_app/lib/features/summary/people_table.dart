import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/summary.dart';
import 'summary_widgets.dart';

enum PeopleSort { person, status, targets, volume }

/// Each person with status, how their targets went and their volume.
/// Click a column header to sort. Missing people come first by default.
class PeopleTableCard extends StatefulWidget {
  const PeopleTableCard({super.key, required this.people});

  final List<PersonSummary> people;

  @override
  State<PeopleTableCard> createState() => _PeopleTableCardState();
}

class _PeopleTableCardState extends State<PeopleTableCard> {
  PeopleSort _sort = PeopleSort.status;
  bool _ascending = true;
  String _query = '';
  bool _missingOnly = false;
  int _limit = _pageSize;

  /// Rows built at first; the rest wait behind a button so 300 people stay
  /// quick to scroll.
  static const _pageSize = 100;

  static const _minWidth = 600.0;

  void _tap(PeopleSort s) => setState(() {
    if (_sort == s) {
      _ascending = !_ascending;
    } else {
      _sort = s;
      // Numbers start with the biggest, words and status with the first.
      _ascending = s == PeopleSort.person || s == PeopleSort.status;
    }
  });

  List<PersonSummary> _sorted() {
    final indexed = [
      for (var i = 0; i < widget.people.length; i++) (i, widget.people[i]),
    ];
    int cmp((int, PersonSummary) a, (int, PersonSummary) b) {
      final x = a.$2;
      final y = b.$2;
      final c = switch (_sort) {
        PeopleSort.person => x.name.toLowerCase().compareTo(
          y.name.toLowerCase(),
        ),
        // Missing (false) sorts before sent.
        PeopleSort.status => (x.submitted ? 1 : 0).compareTo(
          y.submitted ? 1 : 0,
        ),
        PeopleSort.targets => _rate(x).compareTo(_rate(y)),
        PeopleSort.volume => x.volumeTotal.compareTo(y.volumeTotal),
      };
      final signed = _ascending ? c : -c;
      return signed != 0 ? signed : a.$1.compareTo(b.$1);
    }

    final q = _query.trim().toLowerCase();
    return ([...indexed]..sort(cmp))
        .map((e) => e.$2)
        .where((p) => !_missingOnly || !p.submitted)
        .where(
          (p) =>
              q.isEmpty ||
              p.name.toLowerCase().contains(q) ||
              p.role.toLowerCase().contains(q) ||
              p.team.toLowerCase().contains(q),
        )
        .toList();
  }

  static double _rate(PersonSummary p) {
    final n = p.met + p.partly + p.missed;
    if (!p.submitted) return -1;
    return n == 0 ? 0 : p.met / n;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final all = _sorted();
    final rows = all.take(_limit).toList();
    final missing = widget.people.where((p) => p.active && !p.submitted).length;
    return ChartCard(
      title: 'People',
      explain:
          '$missing still to send. Click a column '
          'title to sort.',
      child: widget.people.isEmpty
          ? Text(
              'No one is expected to report in this period.',
              style: bodyStyle(context, color: t.muted),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final table = Column(
                  key: const ValueKey('people-table'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context),
                    for (final p in rows) _PersonRow(person: p),
                    if (all.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          _missingOnly && _query.trim().isEmpty
                              ? 'Everyone has sent.'
                              : 'No one matches. Clear the search or show '
                                    'everyone.',
                          style: bodyStyle(context, color: t.muted),
                        ),
                      ),
                    if (all.length > rows.length)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: GhostButton(
                            key: const ValueKey('people-show-more'),
                            label:
                                'Show ${all.length - rows.length} more '
                                '(${rows.length} of ${all.length} shown)',
                            onPressed: () =>
                                setState(() => _limit += _pageSize),
                          ),
                        ),
                      ),
                  ],
                );
                Widget wrapped = table;
                // Bigger text needs a wider table.
                final minWidth =
                    _minWidth * MediaQuery.textScalerOf(context).scale(1);
                if (c.maxWidth < minWidth) {
                  wrapped = SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: minWidth, child: table),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_filters(context), wrapped],
                );
              },
            ),
    );
  }

  Widget _filters(BuildContext context) {
    final search = TextField(
      key: const ValueKey('people-search'),
      // Read out as the field's name; the hint vanishes once typing starts.
      decoration: xInput(context).copyWith(
        hintText: 'Search by name, role or team',
        prefixIcon: const Icon(Icons.search),
      ),
      onChanged: (v) => setState(() {
        _query = v;
        _limit = _pageSize;
      }),
    );
    final only = FilterChip(
      key: const ValueKey('people-missing-only'),
      label: const Text('Missing only'),
      selected: _missingOnly,
      onSelected: (v) => setState(() {
        _missingOnly = v;
        _limit = _pageSize;
      }),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, minWidth: 220),
            child: Semantics(
              label: 'Search the people table',
              container: true,
              child: search,
            ),
          ),
          only,
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.tokens;
    Widget cell(
      PeopleSort s,
      String label, {
      TextAlign align = TextAlign.left,
    }) {
      final active = _sort == s;
      final dir = _ascending ? 'ascending' : 'descending';
      return Semantics(
        button: true,
        label: active ? 'Sort by $label, now $dir' : 'Sort by $label',
        excludeSemantics: true,
        onTap: () => _tap(s),
        child: InkWell(
          key: ValueKey('sort-${s.name}'),
          onTap: () => _tap(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: align == TextAlign.right
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      context,
                      size: 12,
                      color: active ? t.ink : t.muted,
                      weight: FontWeight.w500,
                    ),
                  ),
                ),
                if (active)
                  Icon(
                    _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 14,
                    color: t.ink,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          Expanded(flex: 5, child: cell(PeopleSort.person, 'Person')),
          Expanded(flex: 2, child: cell(PeopleSort.status, 'Status')),
          Expanded(flex: 4, child: cell(PeopleSort.targets, 'Targets')),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: cell(PeopleSort.volume, 'Volume', align: TextAlign.right),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person});

  final PersonSummary person;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = person;
    final label = StringBuffer(
      '${p.name}, ${p.role}, ${p.team}${p.active ? '' : ', inactive'}: ',
    );
    if (p.submitted) {
      label.write(
        'report sent. ${p.met} met, ${p.partly} partly, ${p.missed} missed. '
        'Volume ${fmtInt(p.volumeTotal)}.',
      );
    } else {
      label.write('report missing.');
    }
    return Semantics(
      container: true,
      label: label.toString(),
      child: ExcludeSemantics(
        child: Container(
          key: ValueKey('person-row-${p.assignmentId}'),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: t.line.withValues(alpha: 0.6)),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            p.name,
                            style: bodyStyle(
                              context,
                              size: 15,
                              weight: FontWeight.w500,
                              height: 1.3,
                            ),
                          ),
                          if (!p.active)
                            Container(
                              key: ValueKey('inactive-${p.assignmentId}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: t.soft,
                                border: Border.all(color: t.line),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Inactive',
                                style: bodyStyle(
                                  context,
                                  size: 12,
                                  weight: FontWeight.w700,
                                  color: t.muted,
                                  height: 1.4,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        '${p.role} · ${p.team}',
                        style: bodyStyle(
                          context,
                          size: 13,
                          color: t.muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _StatusChip(sent: p.submitted),
                ),
              ),
              Expanded(flex: 4, child: _Targets(person: p)),
              Expanded(
                flex: 2,
                child: Text(
                  p.submitted ? fmtInt(p.volumeTotal) : '–',
                  textAlign: TextAlign.right,
                  style: monoStyle(context, size: 14, color: t.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.sent});

  final bool sent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: sent ? t.ok : t.warn,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        sent ? 'Sent' : 'Missing',
        style: bodyStyle(
          context,
          size: 12,
          weight: FontWeight.w700,
          color: sent ? t.onOk : t.onWarn,
          height: 1.3,
        ),
      ),
    );
  }
}

class _Targets extends StatelessWidget {
  const _Targets({required this.person});

  final PersonSummary person;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = person;
    final n = p.met + p.partly + p.missed;
    if (!p.submitted || n == 0) {
      return Text(
        p.submitted ? 'No targets' : '–',
        style: bodyStyle(context, size: 13, color: t.muted),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StackedBar(
            height: 8,
            parts: [
              BarPart(p.met, t.ok),
              BarPart(p.partly, t.warn),
              BarPart(p.missed, t.bad),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${p.met} met · ${p.partly} partly · ${p.missed} missed',
            style: bodyStyle(context, size: 12, color: t.muted, height: 1.2),
          ),
        ],
      ),
    );
  }
}
