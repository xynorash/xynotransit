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
    this.username,
    this.hasPassword = false,
    this.mustChangePassword = false,
    this.sessionEpoch = 0,
    this.recentLinkSession = false,
    this.viaLink = false,
    this.issuedAt,
  });
  final String? personId;
  final AppRole role;
  final String label;

  /// The name they sign in with, when known.
  final String? username;
  final bool hasPassword;

  /// A manager gave them a temporary password: nothing works until they
  /// choose their own.
  final bool mustChangePassword;

  /// In-memory sessions only: the password epoch this session was made in.
  /// A password change ends every session with an older epoch.
  final int sessionEpoch;

  /// Signed in by a link a few minutes ago (the server decides, at most 15
  /// minutes): the person may choose a new password without the old one.
  final bool recentLinkSession;

  /// In-memory sessions only: this session began with a link, and when. The
  /// demo repository applies the 15 minute rule from these two.
  final bool viaLink;
  final DateTime? issuedAt;

  AppUser copyWith({
    String? username,
    bool? hasPassword,
    bool? mustChangePassword,
    int? sessionEpoch,
    bool? recentLinkSession,
  }) => AppUser(
    personId: personId,
    role: role,
    label: label,
    username: username ?? this.username,
    hasPassword: hasPassword ?? this.hasPassword,
    mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    sessionEpoch: sessionEpoch ?? this.sessionEpoch,
    recentLinkSession: recentLinkSession ?? this.recentLinkSession,
    viaLink: viaLink,
    issuedAt: issuedAt,
  );

  bool get isController => role == AppRole.controller;
}

/// A one time sign-in link a manager made for a person.
class SignInLink {
  const SignInLink({
    required this.url,
    required this.expiresAt,
    required this.personId,
    this.recovery = false,
  });
  final String url;
  final DateTime expiresAt;
  final String personId;

  /// The link lets the person choose a new password without the old one.
  /// Only a person who has a password can get such a link.
  final bool recovery;
}

/// The server ended the sessions of the person after too many wrong current
/// passwords. The app signs out and tells them in plain words.
class SignedOutForSafety extends RepositoryException {
  const SignedOutForSafety()
    : super(
        'You were signed out for safety after too many wrong passwords. '
        'Sign in again.',
      );
  // Same words as PasswordRules.signedOutForSafety (the domain layer is not
  // imported here); a test holds the two together.
}

/// A temporary password a manager made for a person. Shown once.
class TempPassword {
  const TempPassword({required this.username, required this.password});
  final String username;
  final String password;
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
    String? username,
  });

  /// Manager only. Makes a random temporary password for the person. It is
  /// returned once and never stored in clear. The person must choose their own
  /// at the next sign-in; their old sessions end. Making another replaces it.
  /// Throws [RepositoryException] with plain words when it is refused (not a
  /// manager, person switched off, too many resets).
  Future<TempPassword> resetPassword(String personId);

  /// Manager only. Takes the password away: the person signs in with links
  /// only again, and their sessions end.
  Future<void> removePassword(String personId);

  /// Manager only. Makes a single use sign-in link for the person, valid for
  /// [hours] (1 to 168). Earlier links stay valid until used or expired.
  /// Throws [RepositoryException] with plain words when it is refused (not a
  /// manager, person switched off, too many links).
  Future<SignInLink> createSignInLink(
    String personId, {
    int hours = 24,
    bool recovery = false,
  });

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

  /// Signs in with a username and a password. Throws [RepositoryException]
  /// with the server's words: wrong username or password, or too many tries
  /// (an [ApiException] with `retryAfterSeconds` set).
  Future<void> signInWithPassword(String username, String password);

  /// Changes the password of the signed-in person and swaps in the fresh
  /// session. [currentPassword] is needed when the person has a password.
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  });

  Future<void> signOut();
}

/// Sign-in by the one time token in an emailed link.
abstract class LinkSignIn {
  /// Trades the token from the link for a session.
  /// Throws [RepositoryException] with a readable message when it is refused.
  Future<void> exchangeToken(String token);
}
