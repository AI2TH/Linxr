/// Centralized defaults — single source of truth for all hardcoded scalar values.
///
/// Changing a default requires editing only this file.
class SshDefaults {
  SshDefaults._();

  static const String host     = '127.0.0.1';
  static const int    port     = 2222;
  static const String username = 'root';
  static const String password = 'alpine';
}