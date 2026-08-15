/// App configuration. Override values at build time:
/// flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
///              --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8000');

  static const String defaultUserId =
      String.fromEnvironment('USER_ID', defaultValue: 'demo-patient');

  // Publishable (anon) key — public by design, safe to embed in clients.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://isdnhymtwvhuniswiinn.supabase.co',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_w67JKJ4YdYF-kMJNd2_QXg_FW0ruPs7',
  );
}
