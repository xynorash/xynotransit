import 'package:shared_preferences/shared_preferences.dart';

import '../data/api/api_auth.dart';
import '../data/api/api_client.dart';
import '../data/api/api_repository.dart';
import '../data/memory_repository.dart';
import '../data/repository.dart';
import '../data/seed_data.dart';
import 'config.dart';

class Backend {
  const Backend({
    required this.repository,
    required this.auth,
    this.initialStart,
  });
  final Repository repository;
  final AuthService auth;

  /// Period to open on, when it should not be the default one.
  final DateTime? initialStart;
}

/// Demo mode runs on memory; otherwise the API at API_BASE_URL (see README).
Future<Backend> createBackend(SharedPreferences prefs) async {
  if (AppConfig.demo) return createDemoBackend();
  return createApiBackend(prefs, AppConfig.apiBaseUrl);
}

Backend createDemoBackend() {
  final catalog = buildSeedCatalog();
  final auth = DemoAuth(catalog);
  final repo = MemoryRepository(
    catalog: catalog,
    currentUser: () => auth.currentUser ?? DemoAuth.controller,
    withDemoReports: true,
  );
  return Backend(
    repository: repo,
    auth: auth,
    initialStart: MemoryRepository.demoStart,
  );
}

Future<Backend> createApiBackend(
  SharedPreferences prefs,
  String baseUrl,
) async {
  final client = ApiClient(baseUrl: baseUrl, tokens: TokenStore(prefs));
  final auth = ApiAuthService(client);
  await auth.restore();
  return Backend(repository: ApiRepository(client), auth: auth);
}
