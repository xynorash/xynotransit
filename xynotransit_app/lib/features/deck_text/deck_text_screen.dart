import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/deck_text.dart';
import '../../domain/period.dart';
import '../form/form_screen.dart';
import '../preview/preview_pane.dart';
import '../shell/top_bar.dart';
import 'draft_preview.dart';

const _wideBreakpoint = 1100.0;
const _maxPageWidth = 1760.0;
const _previewWidth = 600.0;

const savedMessage = 'Saved. Regenerate the slides to use these words.';

/// Manager page "Slide text": every word of the deck that can be changed, with
/// a live draft preview of the slides.
class DeckTextScreen extends StatelessWidget {
  const DeckTextScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    appBar: TopBar(screen: Screen.deckText),
    body: _Body(),
  );
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(periodProvider);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxPageWidth),
        child: _Loader(period: period.value),
      ),
    );
  }
}

/// Loads the saved words of the chosen period, then shows the editor. A new
/// period loads again and starts a fresh editor.
class _Loader extends ConsumerStatefulWidget {
  const _Loader({required this.period});

  final Period? period;

  @override
  ConsumerState<_Loader> createState() => _LoaderState();
}

class _LoaderState extends ConsumerState<_Loader> {
  DeckTextsState? _state;
  String? _loadedFor;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_Loader old) {
    super.didUpdateWidget(old);
    if (widget.period?.id != _loadedFor) unawaited(_load());
  }

  Future<void> _load() async {
    final id = widget.period?.id;
    if (id == null) return;
    _loadedFor = id;
    setState(() {
      _state = null;
      _error = null;
    });
    try {
      final s = await ref.read(repositoryProvider).loadDeckTexts(id);
      if (mounted && _loadedFor == id) setState(() => _state = s);
    } on Object catch (e) {
      if (mounted && _loadedFor == id) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final period = widget.period;
    final state = _state;
    // The header with the period picker stays while the words load.
    return _Editor(
      key: ValueKey(_loadedFor),
      period: period,
      loaded: state,
      error: _error,
    );
  }
}

/// Words by group, in the order of [deckTextFields].
Map<DeckTextGroup, List<DeckTextField>> _byGroup() {
  final m = <DeckTextGroup, List<DeckTextField>>{};
  for (final f in deckTextFields) {
    m.putIfAbsent(f.group, () => []).add(f);
  }
  return m;
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, this.period, this.loaded, this.error});

  final Period? period;
  final DeckTextsState? loaded;
  final Object? error;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  DeckTexts _saved = DeckTexts.defaults;
  String? _inheritedFrom;
  bool _ready = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  @override
  void didUpdateWidget(_Editor old) {
    super.didUpdateWidget(old);
    _adopt();
  }

  void _adopt() {
    final s = widget.loaded;
    if (s == null || _ready) return;
    _ready = true;
    _saved = s.texts;
    _inheritedFrom = s.inheritedFrom;
    for (final f in deckTextFields) {
      final c = TextEditingController(text: s.texts[f.key])
        ..addListener(_changed);
      _controllers[f.key] = c;
      _focus[f.key] = FocusNode();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  String _raw(String key) => _controllers[key]?.text ?? _saved[key];

  /// The words as they would be saved: trimmed.
  String _value(String key) => _raw(key).trim();

  String? _error(DeckTextField f) => DeckTexts.check(f, _raw(f.key));

  bool get _hasErrors => deckTextFields.any((f) => _error(f) != null);

  /// What the draft preview shows: typed words, except a field with a problem
  /// keeps its saved words.
  DeckTexts get _draft => DeckTexts.fromJson({
    for (final f in deckTextFields)
      f.key: _error(f) == null ? _value(f.key) : _saved[f.key],
  });

  DeckTexts get _typed => DeckTexts.fromJson({
    for (final f in deckTextFields) f.key: _value(f.key),
  });

  bool get _changedFromSaved => _typed != _saved;

  void _insert(DeckTextField f, String token) {
    final c = _controllers[f.key]!;
    final text = c.text;
    final sel = c.selection;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final ins = '{$token}';
    c.value = TextEditingValue(
      text: text.replaceRange(at, end, ins),
      selection: TextSelection.collapsed(offset: at + ins.length),
    );
    _focus[f.key]!.requestFocus();
  }

  void _reset(DeckTextField f) {
    _controllers[f.key]!.text = f.defaultValue;
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all wording?'),
        content: const Text(
          'This resets every wording to the built-in text. You can still '
          'cancel by not saving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    for (final f in deckTextFields) {
      _controllers[f.key]!.text = f.defaultValue;
    }
  }

  Future<void> _save() async {
    final period = widget.period;
    if (period == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await ref
          .read(repositoryProvider)
          .saveDeckTexts(period.id, _typed);
      if (!mounted) return;
      for (final f in deckTextFields) {
        final c = _controllers[f.key]!;
        if (c.text != result.texts[f.key]) c.text = result.texts[f.key];
      }
      ref.invalidate(deckTextsProvider);
      setState(() {
        _saved = result.texts;
        _inheritedFrom = result.inheritedFrom;
        _message = savedMessage;
        _messageIsError = false;
      });
    } on RepositoryException catch (e) {
      if (mounted) {
        setState(() {
          _message = e.message;
          _messageIsError = true;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _message = 'Could not save. Check your connection and try again.';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final form = _form(context);
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= _wideBreakpoint) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 64),
                  child: form,
                ),
              ),
              SizedBox(
                width: _previewWidth + 16,
                height: double.infinity,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(0, 28, 16, 64),
                  child: _preview(),
                ),
              ),
            ],
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 64),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [form, const SizedBox(height: 28), _preview()],
          ),
        );
      },
    );
  }

  Widget _preview() =>
      _ready ? DraftPreview(draft: _draft) : const SizedBox(height: 120);

  Widget _form(BuildContext context) {
    final t = context.tokens;
    final period = widget.period;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'XNT-LOG-03 · Manager'.toUpperCase(),
          style: monoStyle(
            context,
            size: 13,
            color: t.muted,
          ).copyWith(letterSpacing: 13 * 0.08),
        ),
        const SizedBox(height: 8),
        Semantics(
          header: true,
          child: Text(
            'Slide text',
            style: bodyStyle(
              context,
              size: (MediaQuery.sizeOf(context).width * 0.05)
                  .clamp(28, 38)
                  .toDouble(),
              weight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Choose the words of the meeting deck. Use {placeholders} to fill in '
          'names, teams and counts. Words are kept per period and carried over '
          'to the next one.',
          style: bodyStyle(context, color: t.muted),
        ),
        const SizedBox(height: 20),
        const XCard(child: PeriodFields()),
        const SizedBox(height: 16),
        if (widget.error != null)
          Text(
            'Could not load the words. Check your connection and reload.',
            style: bodyStyle(context, color: t.bad),
          )
        else if (!_ready)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _inheritBanner(context),
          for (final e in _byGroup().entries) ...[
            const SizedBox(height: 16),
            _GroupCard(
              group: e.key,
              children: [
                for (final f in e.value)
                  _FieldBlock(
                    field: f,
                    controller: _controllers[f.key]!,
                    focus: _focus[f.key]!,
                    error: _error(f),
                    period: period,
                    onInsert: (tok) => _insert(f, tok),
                    onReset: () => _reset(f),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          _actions(context),
        ],
      ],
    );
  }

  Widget _inheritBanner(BuildContext context) {
    final from = _inheritedFrom;
    final text = from == null
        ? 'These words are saved for this period.'
        : from == 'defaults'
        ? 'Built-in words. Nobody has changed them yet.'
        : 'These words were carried over from $from.';
    return SoftBanner(
      child: Text(
        text,
        key: const ValueKey('inherit-banner'),
        style: bodyStyle(context, size: 15, height: 1.4),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final t = context.tokens;
    final canSave = !_busy && !_hasErrors && _changedFromSaved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PrimaryButton(
              label: _busy ? 'Saving…' : 'Save',
              onPressed: canSave ? () => unawaited(_save()) : null,
            ),
            GhostButton(
              label: 'Reset all to defaults',
              onPressed: () => unawaited(_resetAll()),
            ),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            child: Text(
              _message!,
              key: const ValueKey('save-message'),
              style: bodyStyle(
                context,
                size: 15,
                color: _messageIsError ? t.bad : t.ink,
                height: 1.4,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.children});

  final DeckTextGroup group;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              group.title,
              style: bodyStyle(
                context,
                size: 20,
                weight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
          for (final c in children) ...[const SizedBox(height: 22), c],
        ],
      ),
    );
  }
}

class _FieldBlock extends StatelessWidget {
  const _FieldBlock({
    required this.field,
    required this.controller,
    required this.focus,
    required this.error,
    required this.period,
    required this.onInsert,
    required this.onReset,
  });

  final DeckTextField field;
  final TextEditingController controller;
  final FocusNode focus;
  final String? error;
  final Period? period;
  final void Function(String token) onInsert;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = field;
    final length = controller.text.trim().runes.length;
    final over = length > f.maxLength;
    final isDate = f.key == 'dateText';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          f.label,
          style: bodyStyle(
            context,
            size: 15,
            weight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          f.help,
          style: bodyStyle(context, size: 14, color: t.muted, height: 1.4),
        ),
        const SizedBox(height: 8),
        Semantics(
          label: f.label,
          textField: true,
          container: true,
          child: TextField(
            key: ValueKey('field-${f.key}'),
            controller: controller,
            focusNode: focus,
            minLines: f.multiline ? 4 : 1,
            maxLines: f.multiline ? 8 : 1,
            decoration: xInput(context).copyWith(
              errorText: null,
              enabledBorder: error == null
                  ? null
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: t.bad, width: 2),
                    ),
            ),
            style: bodyStyle(context),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tok in f.tokens)
              _Chip(
                key: ValueKey('chip-${f.key}-$tok'),
                token: tok,
                onTap: () => onInsert(tok),
              ),
            TextButton(
              key: ValueKey('reset-${f.key}'),
              onPressed: controller.text == f.defaultValue ? null : onReset,
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 36),
                foregroundColor: t.accent,
              ),
              child: Semantics(
                label: 'Reset ${f.label}',
                excludeSemantics: true,
                child: const Text('Reset'),
              ),
            ),
            Text(
              '$length / ${f.maxLength}',
              key: ValueKey('counter-${f.key}'),
              style: monoStyle(
                context,
                size: 13,
                color: over ? t.bad : t.muted,
              ),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              key: ValueKey('error-${f.key}'),
              style: bodyStyle(context, size: 14, color: t.bad, height: 1.4),
            ),
          ),
        ],
        if (isDate) ...[
          const SizedBox(height: 6),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              if (period != null) MeetingDateButton(period: period!),
              Text(
                'Empty shows the meeting date',
                style: bodyStyle(
                  context,
                  size: 14,
                  color: t.muted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A placeholder name that inserts {name} where the cursor is.
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.token, required this.onTap});

  final String token;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: 'Insert placeholder $token',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: t.soft,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                widthFactor: 1,
                child: Text(
                  '{$token}',
                  style: monoStyle(context, size: 13, color: t.ink),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
