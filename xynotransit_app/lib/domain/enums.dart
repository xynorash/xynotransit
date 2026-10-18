enum KpiStatus {
  met,
  partly,
  missed;

  static KpiStatus? tryParse(String? s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return null;
  }
}

/// Highlights, lowlights, next three months.
enum NoteKind {
  well,
  wrong,
  next;

  /// Box title in the form.
  String get formTitle => switch (this) {
    NoteKind.well => 'Went well',
    NoteKind.wrong => 'Went wrong',
    NoteKind.next => 'Next 3 months',
  };

  /// Column title on the slides.
  String get slideTitle => switch (this) {
    NoteKind.well => 'Highlights',
    NoteKind.wrong => 'Lowlights',
    NoteKind.next => 'Next 3 months',
  };
}

enum ReportStatus { draft, submitted }

enum PeriodStatus { open, closed }

enum AppRole { contributor, controller }
