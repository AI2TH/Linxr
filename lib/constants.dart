/// Centralized defaults — single source of truth for all hardcoded scalar values.
///
/// Changing a default requires editing only this file.
class SshDefaults {
  SshDefaults._();

  static const String host     = '127.0.0.1';
  static const int    port     = 2222;
  static const String username = 'root';

  /// Password baked into the base image. The app replaces it with a
  /// per-install password (see SshCredentials); it is only used as a
  /// fallback to reach a VM that has not applied that password yet.
  static const String legacyPassword = 'alpine';
}