import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:linxr/services/desktop_service.dart';
import 'package:linxr/services/vm_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.ai2th.linxr/vm');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (methodCall.method == 'getDesktopStatus') {
        return {
          'installed': true,
          'running': true,
          'wm': 'openbox',
          'resolution': '1280x720',
          'novnc_port': 6080,
          'vnc_port': 5900,
        };
      } else if (methodCall.method == 'startDesktop') {
        return {
          'status': 'started',
          'running': true,
          'wm': methodCall.arguments['wm'] ?? 'openbox',
          'resolution': methodCall.arguments['resolution'] ?? '1280x720',
        };
      } else if (methodCall.method == 'stopDesktop') {
        return {'status': 'stopped', 'running': false};
      } else if (methodCall.method == 'launchDesktopApp') {
        return {'status': 'launched', 'app': methodCall.arguments['app']};
      }
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('DesktopService Static Presets & Helpers', () {
    test('resolutions preset contains common resolutions including 20:9 phone ultrawide', () {
      final resList = DesktopService.resolutions;
      expect(resList, isNotEmpty);
      expect(resList.any((r) => r.value == '1280x720'), isTrue);
      expect(resList.any((r) => r.value == '1600x720'), isTrue);
      expect(resList.any((r) => r.value == '1920x1080'), isTrue);
    });

    test('windowManagers preset contains Openbox and XFCE4', () {
      final wmList = DesktopService.windowManagers;
      expect(wmList.any((w) => w.value == 'openbox'), isTrue);
      expect(wmList.any((w) => w.value == 'xfce4'), isTrue);
    });

    test('getNoVncUrl generates proper URL with autoconnect and scale parameters', () {
      final url = DesktopService.getNoVncUrl();
      expect(url.toString(), contains('localhost:6080/vnc.html'));
      expect(url.queryParameters['autoconnect'], 'true');
      expect(url.queryParameters['resize'], 'scale');
      expect(url.queryParameters['show_dot'], 'true');
      expect(url.queryParameters['reconnect'], 'true');
    });

    test('getDesktopStatus invokes platform channel', () async {
      final status = await DesktopService.getStatus();
      expect(status['installed'], isTrue);
      expect(status['running'], isTrue);
      expect(status['wm'], 'openbox');
      expect(status['novnc_port'], 6080);
      expect(log.any((c) => c.method == 'getDesktopStatus'), isTrue);
    });

    test('startDesktop invokes platform channel with wm and resolution', () async {
      final res = await DesktopService.start(resolution: '1600x720', wm: 'xfce4');
      expect(res['status'], 'started');
      expect(res['wm'], 'xfce4');
      expect(res['resolution'], '1600x720');
      expect(log.any((c) => c.method == 'startDesktop'), isTrue);
    });

    test('stopDesktop invokes platform channel', () async {
      final res = await DesktopService.stop();
      expect(res['status'], 'stopped');
      expect(log.any((c) => c.method == 'stopDesktop'), isTrue);
    });

    test('launchApp invokes platform channel with app identifier', () async {
      final res = await DesktopService.launchApp('terminal');
      expect(res['status'], 'launched');
      expect(res['app'], 'terminal');
      expect(log.any((c) => c.method == 'launchDesktopApp'), isTrue);
    });
  });

  group('VmState Desktop Reactive State', () {
    test('VmState reacts to desktop status changes and updates getters', () async {
      final vm = VmState();
      expect(vm.isDesktopRunning, isFalse);
      expect(vm.isDesktopLoading, isFalse);

      await vm.refreshDesktopStatus(force: true);
      expect(vm.isDesktopRunning, isTrue);
      expect(vm.desktopStatus['wm'], 'openbox');
      expect(vm.desktopStatus['resolution'], '1280x720');

      await vm.stopDesktop();
      expect(vm.isDesktopRunning, isFalse);
    });
  });
}
