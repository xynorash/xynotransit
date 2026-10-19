import '../domain/admin.dart';
import '../domain/catalog.dart';
import '../domain/deck.dart';
import '../domain/deck_text.dart';
import '../domain/enums.dart';
import '../domain/summary.dart';
import '../domain/period.dart';
import '../domain/report.dart';

/// A failure with words a person can read. Shown as is in the UI.
class RepositoryException implements Exception {
  const RepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// No connection, or the server did not answer. Worth retrying later.
class NetworkException implements Exception {
  const NetworkException([this.message = 'No connection']);
  final String message;
  @override
  String toString() => message;
}

/// The signed-in person. [personId] is null for someone not linked to a person yet.
class AppUser {
  const AppUser({
    required this.personId,
    required this.role,
    required this.label,
  });
  final String? personId;
  final AppRole role;
  final String label;

  bool get isController => role == AppRole.controller;
}

/// A one time sign-in link a manager made for a person.
class SignInLink {
  const SignInLink({
    required this.url,
    required this.expiresAt,
    required this.personId,
  });
  final String url;
  final DateTime expiresAt;
  final String personId;
}

abstract class Repository {
  /// Teams, people and seats. Managers can ask for the inactive ones too.
  Future<Catalog> loadCatalog({bool includeInactive = false});

  /// The catalog now, and again after every change to it. Replays the latest
  /// value to new listeners.
  Stream<Catalog> watchCatalog({bool includeInactive = false});

  /// Returns the period starting at [startMonth], creating it when missing.
  Future<Period> ensurePeriod(DateTime startMonth);

  Future<void> setMeetingDate(String periodId, DateTime? date);

  /// Every report of the period, live. Emits again on every change.
  Stream<List<Report>> watchReports(String periodId);

  Future<Report?> getReport(String periodId, String assignmentId);

  /// Replaces any earlier report for the same period and assignment.
  /// Throws [RepositoryException] with a readable message when it is refused.
  Future<Report> sendReport(Report report);

  /// Latest generated deck of the period, live.
  Stream<DeckRun?> watchDeck(String periodId);

  /// Manager only. Freezes the submitted reports into a new deck run.
  /// Works with any number of reports, including none.
  Future<DeckRun> generateDeck(Period period, Catalog catalog);

  // ---- Manager only: who reports, on what ----

  /// Creates a team, or renames it when [id] is given.
  Future<Team> saveTeam({String? id, required String name});

  /// Only a team without seats can go.
  Future<void> deleteTeam(String id);

  /// Creates or updates a person. The email is how they sign in. A new person
  /// with an empty [email] gets an internal address made from the name
  /// (rosa.rakoto@xynotransit.internal) that never receives mail; an empty
  /// [email] on an existing person keeps the address they have. The person
  /// that comes back has the address.
  Future<Person> savePerson({
    String? id,
    required String fullName,
    required String email,
    required AppRole role,
    bool active = true,
  });

  /// Manager only. Makes a single use sign-in link for the person, valid for
  /// [hours] (1 to 168). Earlier links stay valid until used or expired.
  /// Throws [RepositoryException] with plain words when it is refused (not a
  /// manager, person switched off, too many links).
  Future<SignInLink> createSignInLink(String personId, {int hours = 24});

  /// Creates or updates a seat: who does what in which team.
  Future<Assignment> saveAssignment({
    String? id,
    required String personId,
    required String teamId,
    required String roleTitle,
    bool active = true,
  });

  /// Replaces the counts and the targets of a seat. Entries keep their id when
  /// they come back with it, new ones are added, missing ones are retired (old
  /// reports keep them). The list order is the order on the form and the slides.
  Future<Assignment> saveDefinitions(
    String assignmentId, {
    required List<MetricInput> metrics,
    required List<KpiInput> kpis,
  });

  /// Any signed-in person. The words of the deck in force for the period: its own, or
  /// carried over from the latest earlier period, or the built-in ones.
  Future<DeckTextsState> loadDeckTexts(String periodId);

  /// Manager only. Saves the words for the period. They are frozen into the deck
  /// at the next generation; an existing deck keeps the words it was made with.
  Future<DeckTextsState> saveDeckTexts(String periodId, DeckTexts texts);

  /// Numbers for the summary dashboard: the period plus [trend] periods back.
  Future<Summary> loadSummary(String periodId, {int trend = 6});
}

abstract class AuthService {
  /// Null while signed out.
  Stream<AppUser?> get userChanges;
  AppUser? get currentUser;

  /// Whether sign-in is by email link. Demo mode skips it.
  bool get needsSignIn;

  Future<void> signInWithEmail(String email);
  Future<void> signOut();
}

/// Sign-in by the one time token in an emailed link.
abstract class LinkSignIn {
  /// Trades the token from the link for a session.
  /// Throws [RepositoryException] with a readable message when it is refused.
  Future<void> exchangeToken(String token);
}
