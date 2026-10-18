import '../domain/catalog.dart';

/// Source of truth for the catalog. `tool/gen_seed.dart` turns this into
/// `xynotransit-db/examples/10-seed.sql`; the in-memory demo repository reads it directly.
class SeedAssignment {
  const SeedAssignment({
    required this.code,
    required this.person,
    required this.team,
    required this.role,
    required this.metrics,
    required this.kpis,
  });
  final String code;
  final String person;
  final String team;
  final String role;
  final List<(String, String)> metrics;
  final List<String> kpis;
}

const seedTeams = <(String, String)>[
  ('mru', 'Mauritius'),
  ('tana', 'Tana'),
  ('abe', 'Antsirabe'),
  ('tmm', 'Tamatave'),
];

const seedAssignments = <SeedAssignment>[
  // Mauritius
  SeedAssignment(
    code: 'shalini',
    person: 'Shalini',
    team: 'mru',
    role: 'Shipping clerk',
    metrics: [],
    kpis: [
      'Shipment advice, contract forms, export documents and letters of credit done',
      'LC opening applied for right first time within 24 hours',
      'Zero late or missed payments from late invoicing or wrong billing',
      'Insurance statements filed on time and accurate',
    ],
  ),
  SeedAssignment(
    code: 'goolsan',
    person: 'Goolsan',
    team: 'mru',
    role: 'Shipping clerk',
    metrics: [],
    kpis: [
      'Monthly courier report issued (Mauritius, Madagascar, others)',
      'Accessories, spare parts and chemicals loaded in the weekly container',
      'Close follow-up on all DHL shipments and invoices',
      'BSC generated before the goods arrive',
    ],
  ),
  // Tana
  SeedAssignment(
    code: 'rova',
    person: 'Rova',
    team: 'tana',
    role: 'Import',
    metrics: [('air', 'Air imports (IM5)'), ('sea', 'Sea imports (IM5)')],
    kpis: [
      'Clearance documents received before the goods arrive',
      'Clearance lead time respected (2 days air, 5 days sea)',
      'All IM5 declarations done on time',
    ],
  ),
  SeedAssignment(
    code: 'rado',
    person: 'Rado',
    team: 'tana',
    role: 'Declarant Ivato (Tana and Abe)',
    metrics: [('air-im8', 'Air IM8 declarations')],
    kpis: [
      'All exports delivered on time',
      'All IM8 declarations done on time',
      'Clearance lead time of 2 days',
      'Répertoire douanier updated',
    ],
  ),
  SeedAssignment(
    code: 'honore',
    person: 'Honore',
    team: 'tana',
    role: 'Passeur Ivato',
    metrics: [
      ('imports', 'Imports followed'),
      ('exports', 'Exports delivered'),
    ],
    kpis: [
      'All IM8 air declarations followed and imports picked up',
      'All exports delivered on time',
      'Clearance lead time of 2 days',
      'Livre noir updated',
    ],
  ),
  SeedAssignment(
    code: 'tanjona',
    person: 'Tanjona',
    team: 'tana',
    role: 'Booking export',
    metrics: [('air', 'Air bookings'), ('sea', 'Sea bookings')],
    kpis: [
      'Zero lateness on bookings',
      '30-day delivery plan updated',
      'Avis d’expédition sent 7 days before ex-factory date',
      'Containers in the factory on time',
      'FDF implemented for the department',
    ],
  ),
  SeedAssignment(
    code: 'tahina-exp',
    person: 'Tahina',
    team: 'tana',
    role: 'Declarant export',
    metrics: [
      ('export', 'Export declarations'),
      ('local', 'Local declarations'),
    ],
    kpis: [
      'Export and re-export declarations done on time',
      'Declarations validated before arrival at port or airport',
      'Local sales and purchases registered and declared',
      'Weekly and monthly export reports sent',
      'Livre noir and Livre répertoire updated',
      'FDF and SharePoint documents conform',
    ],
  ),
  SeedAssignment(
    code: 'hanitra',
    person: 'Hanitra',
    team: 'tana',
    role: 'Invoicing',
    metrics: [
      ('invoices', 'Invoices'),
      ('po', 'Purchase orders'),
      ('tracking', 'Carrier tracking follow-ups'),
    ],
    kpis: [
      'All invoices done right first time',
      'Invoices updated on FDF, SharePoint and MRA',
      'All shipment advice done on time',
      'Original documents dispatched on time',
    ],
  ),
  SeedAssignment(
    code: 'henikaja',
    person: 'Henikaja',
    team: 'tana',
    role: 'Invoicing (Abe Knitwear)',
    metrics: [('invoices', 'Invoices'), ('po', 'Purchase orders')],
    kpis: [
      'All invoices done right first time',
      'Invoices updated on FDF, SharePoint and MRA',
      'Shipment advice shared on time',
      'Original documents dispatched on time',
    ],
  ),
  SeedAssignment(
    code: 'ando',
    person: 'Ando',
    team: 'tana',
    role: 'Invoicing (Abe Knitwear)',
    metrics: [('invoices', 'Invoices'), ('po', 'Purchase orders')],
    kpis: [
      'All invoices done',
      'Invoices updated on FDF, SharePoint and MRA',
      'All shipment advice done on time',
      'Original documents dispatched on time',
    ],
  ),
  // Antsirabe
  SeedAssignment(
    code: 'tahina-bsc',
    person: 'Tahina',
    team: 'abe',
    role: 'BSC creation',
    metrics: [
      ('bsc-abe', 'BSC Abe Knitwear'),
      ('bsc-mada', 'BSC Xynotransit Mada'),
    ],
    kpis: [
      'Documents for BSC received before the goods arrive',
      'BSC validation done on time',
    ],
  ),
  SeedAssignment(
    code: 'tamby',
    person: 'Tamby',
    team: 'abe',
    role: 'Import (Abe Knitwear)',
    metrics: [
      ('air', 'Air imports'),
      ('sea', 'Sea imports'),
      ('courier', 'Courier parcels'),
      ('queries', 'Customs queries answered'),
      ('transfers', 'Bonded transfers'),
    ],
    kpis: [
      'Clearance documents complete before the goods arrive',
      'Lead times respected and declarations submitted on time',
    ],
  ),
  SeedAssignment(
    code: 'michael',
    person: 'Michael',
    team: 'abe',
    role: 'Declarant export (Abe)',
    metrics: [('air', 'Air exports'), ('sea', 'Sea exports')],
    kpis: [
      'Export and re-export declarations done on time',
      'Declarations validated before arrival at port or airport',
      'Certificates of origin received on time',
      'Weekly and monthly export reports sent',
      'Shipment status updated',
      'Livre noir updated',
    ],
  ),
  // Tamatave
  SeedAssignment(
    code: 'andry',
    person: 'Andry',
    team: 'tmm',
    role: 'Tamatave team',
    metrics: [
      ('export', 'Export containers'),
      ('import', 'Import containers'),
      ('reefer', 'Reefer containers'),
      ('empty', 'Empty returns'),
      ('inspections', 'Customs inspections'),
      ('demurrage', 'Demurrage cases'),
      ('delays', 'Vessel delays handled'),
      ('gate', 'Gate passes issued'),
    ],
    kpis: [
      'Import documents received before the vessel arrives',
      'Import clearance within 3 to 4 days',
      'All export containers in before vessel closing',
      'All répertoires douaniers updated',
      'Export, import and late arrival reports sent on time',
    ],
  ),
];

String _slug(String s) => s.toLowerCase();

/// In-memory catalog with readable ids (codes), used by demo mode and tests.
Catalog buildSeedCatalog() {
  final teams = [
    for (var i = 0; i < seedTeams.length; i++)
      Team(
        id: seedTeams[i].$1,
        code: seedTeams[i].$1,
        name: seedTeams[i].$2,
        sort: i + 1,
      ),
  ];
  final persons = <Person>[];
  for (final a in seedAssignments) {
    if (!persons.any((p) => p.id == 'p-${_slug(a.person)}')) {
      persons.add(
        Person(
          id: 'p-${_slug(a.person)}',
          fullName: a.person,
          email: '${_slug(a.person)}@xynotransit.example',
        ),
      );
    }
  }
  final assignments = <Assignment>[];
  final sortInTeam = <String, int>{};
  for (final a in seedAssignments) {
    final sort = (sortInTeam[a.team] ?? 0) + 1;
    sortInTeam[a.team] = sort;
    assignments.add(
      Assignment(
        id: a.code,
        code: a.code,
        personId: 'p-${_slug(a.person)}',
        teamId: a.team,
        roleTitle: a.role,
        sort: sort,
        metrics: [
          for (var i = 0; i < a.metrics.length; i++)
            MetricDef(
              id: '${a.code}/${a.metrics[i].$1}',
              key: a.metrics[i].$1,
              label: a.metrics[i].$2,
              series: i,
            ),
        ],
        kpis: [
          for (var i = 0; i < a.kpis.length; i++)
            KpiDef(id: '${a.code}/k${i + 1}', sort: i + 1, text: a.kpis[i]),
        ],
      ),
    );
  }
  return Catalog(teams: teams, persons: persons, assignments: assignments);
}
