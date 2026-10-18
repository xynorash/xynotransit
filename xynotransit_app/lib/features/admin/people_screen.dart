import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';
import '../shell/top_bar.dart';
import 'admin_providers.dart';
import 'definitions_dialog.dart';
import 'person_dialog.dart';

/// The People screen with its app bar. The router mounts [PeopleScreenBody].
class PeopleScreen extends StatelessWidget {
  const PeopleScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    appBar: TopBar(screen: Screen.people),
    body: PeopleScreenBody(),
  );
}

/// Who reports, in which team, on what. Everything is typed in here, nothing
/// is fixed in the code.
class PeopleScreenBody extends ConsumerStatefulWidget {
  const PeopleScreenBody({super.key});

  @override
  ConsumerState<PeopleScreenBody> createState() => _PeopleScreenBodyState();
}

class _PeopleScreenBodyState extends ConsumerState<PeopleScreenBody> {
  bool _showInactive = false;

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(adminCatalogProvider);
    return catalog.when(
      data: (c) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
            children: _content(context, c),
          ),
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load the people. Check your connection and reload.',
            style: bodyStyle(context),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, Catalog c) {
    final t = context.tokens;
    final persons = {for (final p in c.persons) p.id: p};
    bool visible(Assignment a) =>
        _showInactive || (a.active && (persons[a.personId]?.active ?? false));
    final seats = c.assignments.where(visible).toList();
    final seated = {for (final a in c.assignments) a.personId};
    final unseated = c.persons
        .where((p) => !seated.contains(p.id) && (_showInactive || p.active))
        .toList();
    return [
      Semantics(
        header: true,
        child: Text(
          'People and what they report',
          style: bodyStyle(
            context,
            size: 28,
            weight: FontWeight.w700,
            height: 1.2,
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        'Set up your teams, add the people, and decide what each one counts '
        'and is judged on. The report form and the slides follow what you '
        'write here.',
        style: bodyStyle(context, size: 16, color: t.muted, height: 1.45),
      ),
      const SizedBox(height: 16),
      _TeamsCard(catalog: c),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PrimaryButton(
            label: 'Add a person',
            onPressed: () => showPersonDialog(context),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                key: const Key('show-inactive'),
                value: _showInactive,
                onChanged: (v) => setState(() => _showInactive = v),
              ),
              Flexible(
                child: Text(
                  'Show inactive people and seats',
                  style: bodyStyle(context, size: 15),
                ),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (c.teams.isEmpty && c.persons.isEmpty)
        DashedBox(
          child: Text(
            'Nothing here yet. Add a team, then add the first person.',
            textAlign: TextAlign.center,
            style: bodyStyle(context, color: t.muted),
          ),
        ),
      for (final team in c.teams) ...[
        _TeamSeats(
          team: team,
          seats: seats.where((a) => a.teamId == team.id).toList(),
          catalog: c,
        ),
        const SizedBox(height: 12),
      ],
      if (unseated.isNotEmpty)
        XCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'People without a seat',
                  style: bodyStyle(context, size: 18, weight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 8),
              for (final p in unseated)
                _PersonLine(person: p, subtitle: 'No seat yet'),
            ],
          ),
        ),
    ];
  }
}

class _TeamsCard extends ConsumerStatefulWidget {
  const _TeamsCard({required this.catalog});
  final Catalog catalog;

  @override
  ConsumerState<_TeamsCard> createState() => _TeamsCardState();
}

class _TeamsCardState extends ConsumerState<_TeamsCard> {
  final _new = TextEditingController();
  final _rename = TextEditingController();
  String? _renaming;
  String? _message;
  bool _isError = false;

  @override
  void dispose() {
    _new.dispose();
    _rename.dispose();
    super.dispose();
  }

  void _say(String m, bool e) => setState(() {
    _message = m;
    _isError = e;
  });

  Future<void> _run(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) _say(ok, false);
    } catch (e) {
      if (mounted) _say(adminErrorText(e), true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = widget.catalog;
    final repo = ref.read(repositoryProvider);
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Teams',
              style: bodyStyle(context, size: 20, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 10),
          if (c.teams.isEmpty)
            Text(
              'No team yet.',
              style: bodyStyle(context, size: 15, color: t.muted),
            ),
          for (final team in c.teams)
            _renaming == team.id
                ? _renameRow(team, repo)
                : _teamRow(context, team, repo, c),
          const SizedBox(height: 10),
          Labeled(
            label: 'New team name',
            child: TextField(
              key: const Key('new-team'),
              controller: _new,
              style: bodyStyle(context),
              decoration: xInput(context, hint: 'For example Operations'),
              onSubmitted: (_) => _add(repo),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: GhostButton(
              label: 'Add a team',
              onPressed: () => _add(repo),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
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
        ],
      ),
    );
  }

  Future<void> _add(Repository repo) async {
    final name = _new.text.trim();
    if (name.isEmpty) return _say('Type a name for the team.', true);
    await _run(() async {
      await repo.saveTeam(name: name);
      _new.clear();
    }, 'Team added.');
  }

  Widget _teamRow(BuildContext context, Team team, Repository repo, Catalog c) {
    final seats = c.assignmentsOfTeam(team).length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 420),
            child: Text(
              '${team.name}  ($seats ${seats == 1 ? 'seat' : 'seats'})',
              style: bodyStyle(context, size: 16, weight: FontWeight.w500),
            ),
          ),
          SmallButton(
            label: 'Rename',
            semanticLabel: 'Rename ${team.name}',
            onPressed: () => setState(() {
              _renaming = team.id;
              _rename.text = team.name;
            }),
          ),
          SmallButton(
            label: 'Delete',
            semanticLabel: 'Delete ${team.name}',
            onPressed: () =>
                _run(() => repo.deleteTeam(team.id), 'Team deleted.'),
          ),
        ],
      ),
    );
  }

  Widget _renameRow(Team team, Repository repo) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Labeled(
            label: 'Team name',
            child: TextField(
              key: const Key('rename-team'),
              controller: _rename,
              autofocus: true,
              style: bodyStyle(context),
              decoration: xInput(context),
              onSubmitted: (_) => _saveRename(team, repo),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              SmallButton(
                label: 'Save name',
                onPressed: () => _saveRename(team, repo),
              ),
              SmallButton(
                label: 'Cancel',
                onPressed: () => setState(() => _renaming = null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveRename(Team team, Repository repo) async {
    await _run(() async {
      await repo.saveTeam(id: team.id, name: _rename.text);
      if (mounted) setState(() => _renaming = null);
    }, 'Team renamed.');
  }
}

class _TeamSeats extends StatelessWidget {
  const _TeamSeats({
    required this.team,
    required this.seats,
    required this.catalog,
  });
  final Team team;
  final List<Assignment> seats;
  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return XCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              team.name,
              style: bodyStyle(context, size: 20, weight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          if (seats.isEmpty)
            Text(
              'No seats in this team yet. Open a person and add a seat.',
              style: bodyStyle(context, size: 15, color: t.muted),
            ),
          for (final a in seats)
            _PersonLine(
              person: catalog.personOf(a),
              seat: a,
              subtitle:
                  '${a.roleTitle} · ${a.metrics.length} '
                  '${a.metrics.length == 1 ? 'count' : 'counts'}, '
                  '${a.kpis.length} ${a.kpis.length == 1 ? 'target' : 'targets'}',
            ),
        ],
      ),
    );
  }
}

class _PersonLine extends StatelessWidget {
  const _PersonLine({required this.person, this.seat, required this.subtitle});
  final Person person;
  final Assignment? seat;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final inactive = !person.active || (seat != null && !seat!.active);
    return Opacity(
      opacity: inactive ? 0.6 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: inactive ? t.soft : null,
          border: Border.all(color: t.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  person.fullName,
                  style: bodyStyle(context, size: 17, weight: FontWeight.w700),
                ),
                if (person.appRole.name == 'controller')
                  Text('Manager', style: monoStyle(context, size: 12)),
                if (inactive)
                  Text(
                    'Inactive',
                    style: monoStyle(
                      context,
                      size: 12,
                      weight: FontWeight.w500,
                      color: t.ink,
                    ),
                  ),
              ],
            ),
            Text(
              subtitle,
              style: bodyStyle(context, size: 14, color: t.muted, height: 1.4),
            ),
            if (person.email != null)
              Text(
                person.email!,
                style: monoStyle(context, size: 12),
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                SmallButton(
                  label: 'Edit person',
                  semanticLabel: 'Edit ${person.fullName}',
                  onPressed: () =>
                      showPersonDialog(context, personId: person.id),
                ),
                if (seat != null)
                  SmallButton(
                    label: 'What they count',
                    semanticLabel:
                        'What ${person.fullName} counts as ${seat!.roleTitle}',
                    onPressed: () => showDefinitionsDialog(context, seat!.id),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
