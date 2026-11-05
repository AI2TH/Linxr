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

  static const String defaultWebUrl =
      'http://localhost:6080/vnc.html?autoconnect=true&resize=scale&show_dot=true&reconnect=true';
  static const String vncAddress = '127.0.0.1:5900';

  /// Generates the mobile-optimized noVNC web URI.
  static Uri getNoVncUri({int port = 6080}) {
    return Uri.parse(
      'http://localhost:$port/vnc.html?autoconnect=true&resize=scale&show_dot=true&reconnect=true',
    );
  }

  static Uri getNoVncUrl({int port = 6080}) => getNoVncUri(port: port);

  /// Launches the Virtual Desktop in an in-app Chrome Custom Tab or browser.
  static Future<bool> launchDesktopInApp({
    String? customUrl,
    BuildContext? context,
  }) async {
    final urlStr = customUrl ?? defaultWebUrl;
    final uri = Uri.parse(urlStr);

    try {
      // First attempt: inAppBrowserView (opens seamless inside the app)
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
            content: Text('Could not open browser: $e. You can connect manually to $urlStr'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return false;
    }
  }

  /// Opens the Virtual Desktop in external Chrome/browser for fullscreen usage.
  static Future<bool> launchDesktopExternal({String? customUrl}) async {
    final urlStr = customUrl ?? defaultWebUrl;
    final uri = Uri.parse(urlStr);
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<Map<String, dynamic>> getStatus() =>
      VmPlatform.getDesktopStatus();

  static Future<Map<String, dynamic>> start({
    String resolution = '1280x720',
    String wm = 'openbox',
  }) =>
      VmPlatform.startDesktop(resolution: resolution, wm: wm);

  static Future<Map<String, dynamic>> stop() =>
      VmPlatform.stopDesktop();

  static Future<Map<String, dynamic>> install({
    String mode = 'lightweight',
  }) =>
      VmPlatform.installDesktop(mode: mode);

  static Future<Map<String, dynamic>> launchApp(String app) =>
      VmPlatform.launchDesktopApp(app);
}
