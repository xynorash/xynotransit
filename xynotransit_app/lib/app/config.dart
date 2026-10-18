/// Build-time settings, from `--dart-define`.
abstract final class AppConfig {
  /// Base URL of the API, for example `/api` behind the compose stack or
  /// `http://127.0.0.1:8081/api`. Empty means demo mode.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Run on in-memory data with demo reports. Also the fallback when no
  /// API is configured, so the app always starts.
  static const demoFlag = bool.fromEnvironment('DEMO_MODE');

  static bool get hasApi => apiBaseUrl.isNotEmpty;
  static bool get demo => demoFlag || !hasApi;
}
