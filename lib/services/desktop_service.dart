import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'vm_platform.dart';

class DesktopResolution {
  final String label;
  final String value;
  final String description;

  const DesktopResolution({
    required this.label,
    required this.value,
    required this.description,
  });
}

class DesktopWindowManager {
  final String label;
  final String value;
  final String description;
  final String icon;

  const DesktopWindowManager({
    required this.label,
    required this.value,
    required this.description,
    required this.icon,
  });
}

class DesktopService {
  static const List<DesktopResolution> resolutions = [
    DesktopResolution(
      label: '1280 × 720 (Mobile HD)',
      value: '1280x720',
      description: 'Recommended for phones. Responsive & low memory footprint.',
    ),
    DesktopResolution(
      label: '1600 × 720 (Mobile Wide)',
      value: '1600x720',
      description: 'Matches modern 20:9 smartphone aspect ratio.',
    ),
    DesktopResolution(
      label: '1920 × 1080 (Full HD)',
      value: '1920x1080',
      description: 'High-definition canvas for tablets or desktop apps.',
    ),
    DesktopResolution(
      label: '1024 × 600 (Compact)',
      value: '1024x600',
      description: 'Fastest frame rate on lower-end devices.',
    ),
  ];

  static const List<DesktopWindowManager> windowManagers = [
    DesktopWindowManager(
      label: 'Lightweight (Openbox + Taskbar)',
      value: 'openbox',
      description: 'Ultra-fast (~15MB RAM). Tint2 panel, start menu, and taskbar.',
      icon: '⚡',
    ),
    DesktopWindowManager(
      label: 'Full Desktop (XFCE4)',
      value: 'xfce4',
      description: 'Traditional Linux desktop with panels, app finder, and file manager.',
      icon: '🖥️',
    ),
  ];

  /// App ids accepted by the guest's allow-list (`linxr-desktop app <id>`).
  static const List<String> appIds = ['terminal', 'files', 'editor', 'calculator'];

  static const int defaultWebPort = 6080;
  static const String vncAddress = '127.0.0.1:5900';

  /// noVNC viewer URL tuned for phones:
  /// - `resize=scale` fits the remote screen to the browser window (x11vnc
  ///   cannot resize the Xvfb screen, so `resize=remote` would do nothing);
  /// - `reconnect` + `reconnect_delay` bring the session back after Android
  ///   pauses the browser tab while the app is in the background;
  /// - `show_dot` shows a cursor dot, since a touch screen has no pointer.
  /// 127.0.0.1 rather than localhost: the QEMU port forward listens on IPv4
  /// only, and `localhost` may resolve to ::1 first.
  static Uri buildViewerUri({int port = defaultWebPort}) {
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/vnc.html',
      queryParameters: const {
        'autoconnect': 'true',
        'resize': 'scale',
        'reconnect': 'true',
        'reconnect_delay': '2000',
        'show_dot': 'true',
        'path': 'websockify',
      },
    );
  }

  static String get defaultWebUrl => buildViewerUri().toString();

  static Uri getNoVncUri({int port = defaultWebPort}) => buildViewerUri(port: port);

  static Uri getNoVncUrl({int port = defaultWebPort}) => buildViewerUri(port: port);

  /// A landscape resolution with the phone's aspect ratio, [targetHeight]
  /// pixels high, so the scaled desktop fills the screen without black bars.
  /// The width is a multiple of 8 (friendlier to VNC encoders).
  static DesktopResolution phoneResolution(Size screen, {int targetHeight = 720}) {
    final longSide = screen.width > screen.height ? screen.width : screen.height;
    final shortSide = screen.width > screen.height ? screen.height : screen.width;
    final aspect = shortSide > 0 ? longSide / shortSide : 16 / 9;
    var width = ((targetHeight * aspect) / 8).round() * 8;
    if (width < 960) width = 960;
    if (width > 2400) width = 2400;
    final value = '${width}x$targetHeight';
    return DesktopResolution(
      label: '$width × $targetHeight (Fit this screen)',
      value: value,
      description: 'Same shape as this device in landscape: fills the screen without black bars.',
    );
  }

  /// Presets plus, when known, the phone-shaped resolution and the resolution
  /// currently in use (so a dropdown always contains the selected value).
  static List<DesktopResolution> resolutionOptions({Size? screen, String? current}) {
    final options = <DesktopResolution>[];
    if (screen != null && screen.width > 0 && screen.height > 0) {
      final phone = phoneResolution(screen);
      if (!resolutions.any((r) => r.value == phone.value)) options.add(phone);
    }
    options.addAll(resolutions);
    if (current != null &&
        isValidResolution(current) &&
        !options.any((r) => r.value == current)) {
      final parts = current.split('x');
      options.add(DesktopResolution(
        label: '${parts[0]} × ${parts[1]} (Current)',
        value: current,
        description: 'Resolution of the last desktop session.',
      ));
    }
    return options;
  }

  static bool isValidResolution(String value) {
    final m = RegExp(r'^(\d{3,4})x(\d{3,4})$').firstMatch(value);
    if (m == null) return false;
    final w = int.parse(m.group(1)!);
    final h = int.parse(m.group(2)!);
    return w >= 320 && w <= 4096 && h >= 240 && h <= 4096;
  }

  /// Fraction 0..1 from the guest's `install_progress` ("37/199"), or null.
  static double? installFraction(Map<String, dynamic> status) {
    final p = status['install_progress']?.toString() ?? '';
    final m = RegExp(r'^(\d+)/(\d+)$').firstMatch(p);
    if (m == null) return null;
    final done = int.parse(m.group(1)!);
    final total = int.parse(m.group(2)!);
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }

  /// One-line install progress for the UI.
  static String installProgressText(Map<String, dynamic> status) {
    final progress = status['install_progress']?.toString() ?? '';
    final step = status['install_step']?.toString() ?? '';
    final mode = status['install_mode']?.toString() ?? '';
    final head = 'Installing ${mode.isEmpty ? 'desktop' : mode} packages';
    if (progress.isNotEmpty) return '$head ($progress): $step';
    if (step.isNotEmpty) return '$head: $step';
    return '$head...';
  }

  /// Launches the Virtual Desktop in an in-app Chrome Custom Tab or browser.
  static Future<bool> launchDesktopInApp({
    String? customUrl,
    int port = defaultWebPort,
    BuildContext? context,
  }) async {
    final uri = customUrl != null ? Uri.parse(customUrl) : buildViewerUri(port: port);

    try {
      // First attempt: inAppBrowserView (a Chrome Custom Tab on Android)
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      );
      if (launched) return true;
    } catch (_) {
      // Fallback below
    }

    try {
      // Second attempt: externalApplication (opens in phone's default browser)
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('Failed to launch Virtual Desktop URL: $e');
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open browser: $e. You can connect manually to $uri'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return false;
    }
  }

  /// Opens the Virtual Desktop in external Chrome/browser for fullscreen usage.
  static Future<bool> launchDesktopExternal({String? customUrl, int port = defaultWebPort}) async {
    final uri = customUrl != null ? Uri.parse(customUrl) : buildViewerUri(port: port);
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<Map<String, dynamic>> getStatus() =>
      VmPlatform.getDesktopStatus();

  /// Starts the desktop. Completes only when the guest reports every
  /// component up; throws a PlatformException whose message says which one
  /// failed otherwise.
  static Future<Map<String, dynamic>> start({
    String resolution = '1280x720',
    String wm = 'openbox',
  }) =>
      VmPlatform.startDesktop(resolution: resolution, wm: wm);

  static Future<Map<String, dynamic>> stop() =>
      VmPlatform.stopDesktop();

  /// Starts the package install in the guest; it returns at once. Use
  /// [waitForInstall] to follow it.
  static Future<Map<String, dynamic>> install({
    String mode = 'lightweight',
  }) =>
      VmPlatform.installDesktop(mode: mode);

  /// Polls the desktop status until the install is no longer running.
  /// Returns the last status; its `install_state` is `ok` or `failed` (or
  /// still `running` if [timeout] passed).
  static Future<Map<String, dynamic>> waitForInstall({
    void Function(Map<String, dynamic> status)? onProgress,
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 45),
    Future<Map<String, dynamic>> Function()? fetchStatus,
  }) async {
    final fetch = fetchStatus ?? getStatus;
    final deadline = DateTime.now().add(timeout);
    var status = <String, dynamic>{};
    var misses = 0;
    while (DateTime.now().isBefore(deadline)) {
      status = await fetch();
      final state = status['install_state']?.toString() ?? '';
      if (status.isEmpty || state.isEmpty) {
        // The VM API did not answer; tolerate a few misses (the guest is
        // busy unpacking packages under emulation).
        if (++misses > 15) {
          return {...status, 'install_state': 'failed', 'install_error': 'Lost contact with the VM during the install'};
        }
      } else {
        misses = 0;
        onProgress?.call(status);
        if (state != 'running') return status;
      }
      await Future.delayed(interval);
    }
    return status;
  }

  static Future<String> getLog({String name = 'all', int lines = 300}) =>
      VmPlatform.getDesktopLog(name: name, lines: lines);

  static Future<Map<String, dynamic>> launchApp(String app) =>
      VmPlatform.launchDesktopApp(app);
}
