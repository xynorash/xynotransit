import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/admin.dart';
import '../../domain/catalog.dart';
import 'admin_providers.dart';

/// One line being edited. [id] is null for a new one.
class _Row {
  _Row({this.id, String text = ''})
    : original = text,
      controller = TextEditingController(text: text);
  final String? id;
  final String original;
  final TextEditingController controller;
  final Key key = UniqueKey();
  String get text => controller.text.trim();
}

Future<void> showDefinitionsDialog(BuildContext context, String assignmentId) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: DefinitionsEditor(assignmentId: assignmentId),
      ),
    ),
  );
}

/// 'What they count and what they are judged on': two lists a manager shapes
/// freely, one count or eight, as many targets as they need.
class DefinitionsEditor extends ConsumerStatefulWidget {
  const DefinitionsEditor({super.key, required this.assignmentId});
  final String assignmentId;

  @override
  ConsumerState<DefinitionsEditor> createState() => _DefinitionsEditorState();
}

class _DefinitionsEditorState extends ConsumerState<DefinitionsEditor> {
  final _counts = <_Row>[];
  final _targets = <_Row>[];
  List<String> _savedCountIds = [];
  Map<String, String> _savedTargets = {};
  bool _loaded = false;
  bool _tried = false;
  bool _saving = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    for (final r in [..._counts, ..._targets]) {
      r.controller.dispose();
    }
    super.dispose();
  }

  void _load(Assignment a) {
    for (final r in [..._counts, ..._targets]) {
      r.controller.dispose();
    }
    _counts
      ..clear()
      ..addAll(a.metrics.map((m) => _Row(id: m.id, text: m.label)));
    final kpis = [...a.kpis]..sort((x, y) => x.sort.compareTo(y.sort));
    _targets
      ..clear()
      ..addAll(kpis.map((k) => _Row(id: k.id, text: k.text)));
    _savedCountIds = [for (final m in a.metrics) m.id];
    _savedTargets = {for (final k in kpis) k.id: k.text};
    _loaded = true;
  }

  String? _countError(int i) {
    final t = _counts[i].text;
    if (t.isEmpty) return _tried ? 'Give this count a name.' : null;
    if (t.length > DefinitionRules.maxMetricLabel) {
      return 'Use ${DefinitionRules.maxMetricLabel} characters or fewer.';
    }
    final low = t.toLowerCase();
    for (var j = 0; j < _counts.length; j++) {
      if (j != i && _counts[j].text.toLowerCase() == low) {
        return 'Another count already has this name.';
      }
    }
    return null;
  }

  String? _targetError(int i) {
    final t = _targets[i].text;
    if (t.isEmpty) return _tried ? 'Write the target.' : null;
    if (t.length > DefinitionRules.maxKpiText) {
      return 'Use ${DefinitionRules.maxKpiText} characters or fewer.';
    }
    return null;
  }

  bool get _valid {
    for (var i = 0; i < _counts.length; i++) {
      if (_counts[i].text.isEmpty || _countError(i) != null) return false;
    }
    for (var i = 0; i < _targets.length; i++) {
      if (_targets[i].text.isEmpty || _targetError(i) != null) return false;
    }
    return true;
  }

  bool get _removesOrChanges {
    final keptCounts = {for (final r in _counts) r.id};
    if (_savedCountIds.any((id) => !keptCounts.contains(id))) return true;
    final keptTargets = {for (final r in _targets) r.id: r.text};
    for (final e in _savedTargets.entries) {
      final now = keptTargets[e.key];
      if (now == null || now != e.value.trim()) return true;
    }
    return false;
  }

  void _move(List<_Row> list, int i, int by) {
    final j = i + by;
    if (j < 0 || j >= list.length) return;
    setState(() {
      final r = list.removeAt(i);
      list.insert(j, r);
      _message = null;
    });
  }

  void _remove(List<_Row> list, int i) {
    setState(() {
      list.removeAt(i).controller.dispose();
      _message = null;
    });
  }

  Future<void> _save() async {
    setState(() {
      _tried = true;
      _message = null;
    });
    if (!_valid) {
      setState(() {
        _message = 'Fix the lines marked in red, then save.';
        _messageIsError = true;
      });
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(repositoryProvider)
          .saveDefinitions(
            widget.assignmentId,
            metrics: [
              for (final r in _counts) MetricInput(id: r.id, label: r.text),
            ],
            kpis: [for (final r in _targets) KpiInput(id: r.id, text: r.text)],
          );
      if (!mounted) return;
      setState(() {
        _load(saved);
        _tried = false;
        _saving = false;
        _message = 'Saved.';
        _messageIsError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = adminErrorText(e);
        _messageIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final catalog = ref.watch(adminCatalogProvider);
    final a = catalog.value?.assignmentById(widget.assignmentId);
    if (a == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_loaded) _load(a);
    final person = catalog.value!.personOf(a).fullName;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'What they count and what they are judged on',
                    style: bodyStyle(
                      context,
                      size: 20,
                      weight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Text(
            '$person, ${a.roleTitle}',
            style: bodyStyle(context, size: 15, color: t.muted),
          ),
          const SizedBox(height: 16),
          _section(
            title: 'Counts',
            hint:
                'Name each number this person reports, for example Sea, Air, '
                'Road. One count is fine.',
            rows: _counts,
            noun: 'count',
            max: DefinitionRules.maxMetrics,
            maxText: DefinitionRules.maxMetricLabel,
            maxMessage:
                'A seat can have ${DefinitionRules.maxMetrics} counts at most.',
            addLabel: 'Add a count',
            multiline: false,
            error: _countError,
            withDot: true,
          ),
          const SizedBox(height: 20),
          _section(
            title: 'Targets',
            hint:
                'What this person is judged on. At each report they answer '
                'Met, Partly or Missed and may add a comment.',
            rows: _targets,
            noun: 'target',
            max: DefinitionRules.maxKpis,
            maxText: DefinitionRules.maxKpiText,
            maxMessage:
                'A seat can have at most ${DefinitionRules.maxKpis} targets.',
            addLabel: 'Add a target',
            multiline: true,
            error: _targetError,
            withDot: false,
          ),
          const SizedBox(height: 20),
          _Preview(
            counts: [for (final r in _counts) r.text],
            targets: [for (final r in _targets) r.text],
          ),
          if (_removesOrChanges) ...[
            const SizedBox(height: 12),
            SoftBanner(
              child: Text(
                'You removed or reworded something. Old reports keep what '
                'they were answered against.',
                style: bodyStyle(context, size: 15),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrimaryButton(
                label: _saving ? 'Saving' : 'Save',
                onPressed: _saving ? null : _save,
              ),
              if (_message != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _message!,
                    style: bodyStyle(
                      context,
                      size: 15,
                      weight: FontWeight.w500,
                      color: _messageIsError ? t.bad : t.ink,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String hint,
    required List<_Row> rows,
    required String noun,
    required int max,
    required int maxText,
    required String maxMessage,
    required String addLabel,
    required bool multiline,
    required String? Function(int) error,
    required bool withDot,
  }) {
    final t = context.tokens;
    final full = rows.length >= max;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: bodyStyle(context, size: 17, weight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
        ),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          Text(
            'No $noun${noun == 'count' ? 's' : 's'} yet.',
            style: bodyStyle(context, size: 15, color: t.muted),
          ),
        for (var i = 0; i < rows.length; i++)
          Padding(
            key: rows[i].key,
            padding: const EdgeInsets.only(bottom: 10),
            child: _rowView(
              rows: rows,
              i: i,
              noun: noun,
              maxText: maxText,
              multiline: multiline,
              error: error(i),
              withDot: withDot,
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              GhostButton(
                label: addLabel,
                onPressed: full
                    ? null
                    : () => setState(() {
                        rows.add(_Row());
                        _message = null;
                      }),
              ),
              if (full)
                Text(
                  maxMessage,
                  style: bodyStyle(context, size: 15, color: t.muted),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _rowView({
    required List<_Row> rows,
    required int i,
    required String noun,
    required int maxText,
    required bool multiline,
    required String? error,
    required bool withDot,
  }) {
    final t = context.tokens;
    final n = i + 1;
    final r = rows[i];
    final len = r.controller.text.trim().length;
    final field = Semantics(
      label: '${noun[0].toUpperCase()}${noun.substring(1)} $n',
      textField: true,
      container: true,
      child: TextField(
        key: Key('$noun-field-$i'),
        controller: r.controller,
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 5 : 1,
        keyboardType: multiline ? TextInputType.multiline : TextInputType.text,
        textInputAction: multiline
            ? TextInputAction.newline
            : TextInputAction.next,
        style: bodyStyle(context),
        decoration:
            xInput(
              context,
              hint: multiline ? 'Target $n' : 'Count $n, for example Sea',
            ).copyWith(
              errorText: error,
              errorMaxLines: 3,
              helperText: len > maxText * 0.8 ? '$len/$maxText' : null,
            ),
        onChanged: (_) => setState(() => _message = null),
      ),
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(
          Icons.arrow_upward,
          'Move $noun $n up',
          i == 0 ? null : () => _move(rows, i, -1),
          Key('$noun-up-$i'),
        ),
        _iconBtn(
          Icons.arrow_downward,
          'Move $noun $n down',
          i == rows.length - 1 ? null : () => _move(rows, i, 1),
          Key('$noun-down-$i'),
        ),
        _iconBtn(
          Icons.delete_outline,
          'Remove $noun $n',
          () => _remove(rows, i),
          Key('$noun-remove-$i'),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 520;
        final lead = ExcludeSemantics(
          child: SizedBox(
            width: 26,
            child: withDot
                ? Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: seriesColor(i),
                      shape: BoxShape.circle,
                    ),
                  )
                : Text(
                    '$n',
                    style: monoStyle(context, size: 13, color: t.muted),
                  ),
          ),
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 16), child: lead),
                  Expanded(child: field),
                ],
              ),
              Align(alignment: Alignment.centerRight, child: buttons),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 16), child: lead),
            Expanded(child: field),
            const SizedBox(width: 4),
            buttons,
          ],
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback? onTap, Key key) =>
      IconButton(
        key: key,
        tooltip: label,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: onTap,
        icon: Icon(icon, size: 20),
      );
}

/// What the employee will see on their form, as plain text.
class _Preview extends StatelessWidget {
  const _Preview({required this.counts, required this.targets});
  final List<String> counts;
  final List<String> targets;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'How the form will look',
              style: bodyStyle(context, size: 15, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          if (counts.isEmpty)
            Text(
              'No numbers to fill in.',
              style: bodyStyle(context, size: 15, color: t.muted),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < counts.length; i++)
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: seriesColor(i),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          counts[i].isEmpty ? '(no name yet)' : counts[i],
                          style: bodyStyle(context, size: 15),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          const SizedBox(height: 8),
          if (targets.isEmpty)
            Text(
              'No targets to answer.',
              style: bodyStyle(context, size: 15, color: t.muted),
            )
          else
            for (final x in targets)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${x.isEmpty ? '(no text yet)' : x}  Met / Partly / Missed',
                  style: bodyStyle(context, size: 15, height: 1.4),
                ),
              ),
        ],
      ),
    );
  }
}
