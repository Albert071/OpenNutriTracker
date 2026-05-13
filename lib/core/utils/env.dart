import 'package:envied/envied.dart';

part 'env.g.dart';

@Envied(path: '.env')
abstract class Env {
  @EnviedField(varName: 'FDC_API_KEY', obfuscate: true)
  static final String fdcApiKey = _Env.fdcApiKey;
  @EnviedField(varName: 'SENTRY_DNS', obfuscate: true)
  static final String sentryDns = _Env.sentryDns;
  @EnviedField(varName: 'SUPABASE_PROJECT_URL', obfuscate: true)
  static final String supabaseProjectUrl = _Env.supabaseProjectUrl;
  @EnviedField(varName: 'SUPABASE_PROJECT_ANON_KEY', obfuscate: true)
  static final String supabaseProjectAnonKey = _Env.supabaseProjectAnonKey;
  // Shared bearer token presented in the `X-Catalog-Access` header on
  // every offline-catalog HTTP request. The matching Cloudflare WAF
  // Custom Rule on `catalog.opennutritracker.org` 403s any request
  // whose header does not carry this value, so random crawlers cannot
  // pull the catalog without going through the app. Long-lived by
  // design — rotation is an emergency-only operation that requires a
  // fresh APK build to ship the new value here.
  @EnviedField(varName: 'CATALOG_ACCESS_TOKEN', obfuscate: true)
  static final String catalogAccessToken = _Env.catalogAccessToken;
}
