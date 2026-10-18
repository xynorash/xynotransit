import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../domain/admin.dart';
import '../../domain/catalog.dart';
import '../../domain/enums.dart';
import 'admin_providers.dart';
import 'definitions_dialog.dart';

Future<void> showPersonDialog(BuildContext context, {String? personId}) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: PersonEditor(personId: personId),
      ),
    ),
  );
}

/// Adds a person, or edits one: name, email, role, active, and their seats.
class PersonEditor extends ConsumerStatefulWidget {
  const PersonEditor({super.key, this.personId});
  final String? personId;

  @override
  ConsumerState<PersonEditor> createState() => _PersonEditorState();
}

class _PersonEditorState extends ConsumerState<PersonEditor> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _roleTitle = TextEditingController();
  String? _id;
  AppRole _role = AppRole.contributor;
  bool _active = true;
  bool _loaded = false;
  bool _busy = false;
  String? _teamId;
  String? _message;
  bool _isError = false;
  String? _seatMessage;
  bool _seatIsError = false;

  @override
  void initState() {
    super.initState();
    _id = widget.personId;
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _roleTitle.dispose();
    super.dispose();
  }

  void _fill(Person p) {
    _name.text = p.fullName;
    _email.text = p.email ?? '';
    _role = p.appRole;
    _active = p.active;
    _loaded = true;
  }

  Future<void> _savePerson() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty) {
      return _say('Enter the full name.', true);
    }
    if (name.length > DefinitionRules.maxName) {
      return _say(
        'Use ${DefinitionRules.maxName} characters or fewer for the name.',
        true,
      );
    }
    if (email.isEmpty) return _say('Enter the email they sign in with.', true);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final p = await ref
          .read(repositoryProvider)
          .savePerson(
            id: _id,
            fullName: name,
            email: email,
            role: _role,
            active: _active,
          );
      if (!mounted) return;
      setState(() {
        _id = p.id;
        _busy = false;
        _loaded = true;
        _message = 'Saved.';
        _isError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _say(adminErrorText(e), true);
    }
  }

  void _say(String m, bool error) => setState(() {
    _message = m;
    _isError = error;
  });

  Future<void> _submitSeat() async {
    final title = _roleTitle.text.trim();
    if (_teamId == null) {
      return _seatSay('Choose a team.', true);
    }
    if (title.isEmpty) return _seatSay('Enter the role title.', true);
    if (title.length > DefinitionRules.maxRoleTitle) {
      return _seatSay(
        'Use ${DefinitionRules.maxRoleTitle} characters or fewer.',
        true,
      );
    }
    try {
      await ref
          .read(repositoryProvider)
          .saveAssignment(personId: _id!, teamId: _teamId!, roleTitle: title);
      if (!mounted) return;
      _roleTitle.clear();
      _seatSay('Seat added. Now say what they count.', false);
    } catch (e) {
      if (mounted) _seatSay(adminErrorText(e), true);
    }
  }

  void _seatSay(String m, bool error) => setState(() {
    _seatMessage = m;
    _seatIsError = error;
  });

  Future<void> _toggleSeat(Assignment a, bool active) async {
    try {
      await ref
          .read(repositoryProvider)
          .saveAssignment(
            id: a.id,
            personId: a.personId,
            teamId: a.teamId,
            roleTitle: a.roleTitle,
            active: active,
          );
      if (mounted) _seatSay('Saved.', false);
    } catch (e) {
      if (mounted) _seatSay(adminErrorText(e), true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final catalog = ref.watch(adminCatalogProvider).value;
    final existing = _id == null
        ? null
        : catalog?.persons.where((p) => p.id == _id).firstOrNull;
    if (!_loaded && existing != null) _fill(existing);
    if (widget.personId != null && existing == null && !_loaded) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final editing = _id != null;
    final seats = catalog == null || _id == null
        ? <Assignment>[]
        : catalog.assignments.where((a) => a.personId == _id).toList();
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
                    editing ? 'Edit person' : 'Add a person',
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
          const SizedBox(height: 12),
          Labeled(
            label: 'Full name',
            child: TextField(
              key: const Key('person-name'),
              controller: _name,
              textInputAction: TextInputAction.next,
              style: bodyStyle(context),
              decoration: xInput(context, hint: 'For example Hanitra Rakoto'),
            ),
          ),
          const SizedBox(height: 12),
          Labeled(
            label: 'Email (they sign in with it)',
            child: TextField(
              key: const Key('person-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: bodyStyle(context),
              decoration: xInput(context, hint: 'name@company.com'),
            ),
          ),
          const SizedBox(height: 12),
          Labeled(
            label: 'Role in this app',
            child: SegmentedButton<AppRole>(
              segments: const [
                ButtonSegment(
                  value: AppRole.contributor,
                  label: Text('Employee'),
                ),
                ButtonSegment(
                  value: AppRole.controller,
                  label: Text('Manager'),
                ),
              ],
              selected: {_role},
              onSelectionChanged: (s) => setState(() => _role = s.first),
            ),
          ),
          if (editing) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('person-active'),
              contentPadding: EdgeInsets.zero,
              title: Text('Active', style: bodyStyle(context, size: 16)),
              subtitle: Text(
                'Inactive people cannot sign in and are not expected to '
                'report. Their old reports stay.',
                style: bodyStyle(
                  context,
                  size: 14,
                  color: t.muted,
                  height: 1.4,
                ),
              ),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrimaryButton(
                label: editing ? 'Save person' : 'Add person',
                onPressed: _busy ? null : _savePerson,
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
                      color: _isError ? t.bad : t.ink,
                    ),
                  ),
                ),
            ],
          ),
          if (editing) ...[
            const SizedBox(height: 24),
            Semantics(
              header: true,
              child: Text(
                'Seats',
                style: bodyStyle(context, size: 17, weight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'A seat is a role in a team. A person can have several.',
              style: bodyStyle(context, size: 15, color: t.muted, height: 1.4),
            ),
            const SizedBox(height: 8),
            if (seats.isEmpty)
              Text(
                'No seat yet.',
                style: bodyStyle(context, size: 15, color: t.muted),
              ),
            for (final a in seats) _seatTile(context, catalog!, a),
            const SizedBox(height: 12),
            if (catalog != null && catalog.teams.isEmpty)
              Text(
                'Add a team first, then give this person a seat in it.',
                style: bodyStyle(context, size: 15, color: t.muted),
              )
            else if (catalog != null)
              _addSeat(context, catalog),
          ],
        ],
      ),
    );
  }

  Widget _seatTile(BuildContext context, Catalog catalog, Assignment a) {
    final t = context.tokens;
    final team = catalog.teams.where((x) => x.id == a.teamId).firstOrNull;
    return Opacity(
      opacity: a.active ? 1 : 0.6,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: t.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${a.roleTitle}${a.active ? '' : ' (Inactive)'}',
              style: bodyStyle(context, size: 16, weight: FontWeight.w700),
            ),
            Text(
              '${team?.name ?? 'No team'} · ${_countText(a)}',
              style: bodyStyle(context, size: 14, color: t.muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SmallButton(
                  label: 'What they count',
                  semanticLabel: 'What they count as ${a.roleTitle}',
                  onPressed: () => showDefinitionsDialog(context, a.id),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      key: Key('seat-active-${a.id}'),
                      value: a.active,
                      onChanged: (v) => _toggleSeat(a, v),
                    ),
                    Text('Active seat', style: bodyStyle(context, size: 14)),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _addSeat(BuildContext context, Catalog catalog) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Labeled(
          label: 'Team',
          child: DropdownButtonFormField<String>(
            key: const Key('seat-team'),
            initialValue: _teamId,
            isExpanded: true,
            decoration: xInput(context, hint: 'Choose a team'),
            items: [
              for (final x in catalog.teams)
                DropdownMenuItem(
                  value: x.id,
                  child: Text(x.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _teamId = v),
          ),
        ),
        const SizedBox(height: 10),
        Labeled(
          label: 'Role title',
          child: TextField(
            key: const Key('seat-title'),
            controller: _roleTitle,
            style: bodyStyle(context),
            decoration: xInput(
              context,
              hint: 'For example Freight coordinator',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GhostButton(label: 'Add a seat', onPressed: _submitSeat),
            if (_seatMessage != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _seatMessage!,
                  style: bodyStyle(
                    context,
                    size: 15,
                    weight: FontWeight.w500,
                    color: _seatIsError ? t.bad : t.ink,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

String _countText(Assignment a) {
  final c = a.metrics.length;
  final k = a.kpis.length;
  return '$c ${c == 1 ? 'count' : 'counts'}, $k ${k == 1 ? 'target' : 'targets'}';
}
