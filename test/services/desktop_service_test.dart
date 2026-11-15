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
      expect(url.toString(), contains('127.0.0.1:6080/vnc.html'));
      expect(url.queryParameters['autoconnect'], 'true');
      expect(url.queryParameters['resize'], 'scale');
      expect(url.queryParameters['show_dot'], 'true');
      expect(url.queryParameters['reconnect'], 'true');
      expect(url.queryParameters['reconnect_delay'], '2000');
      expect(url.queryParameters['path'], 'websockify');
    });

    test('buildViewerUri uses the port reported by the guest', () {
      final url = DesktopService.buildViewerUri(port: 16080);
      expect(url.port, 16080);
      expect(url.host, '127.0.0.1');
    });

    test('phoneResolution matches the device aspect ratio at 720 px high', () {
      // Pixel 7 class phone in portrait (logical pixels)
      expect(DesktopService.phoneResolution(const Size(412, 915)).value, '1600x720');
      // Same phone in landscape gives the same answer
      expect(DesktopService.phoneResolution(const Size(915, 412)).value, '1600x720');
      // 16:10 tablet
      expect(DesktopService.phoneResolution(const Size(800, 1280)).value, '1152x720');
      // Width is a multiple of 8 and clamped
      final odd = DesktopService.phoneResolution(const Size(390, 844)).value;
      final w = int.parse(odd.split('x').first);
      expect(w % 8, 0);
      expect(DesktopService.phoneResolution(const Size(100, 1000)).value, '2400x720');
    });

    test('resolutionOptions adds the phone size and keeps a custom current value', () {
      final opts = DesktopService.resolutionOptions(
        screen: const Size(390, 844),
        current: '1366x768',
      );
      final values = opts.map((r) => r.value).toList();
      expect(values.first, DesktopService.phoneResolution(const Size(390, 844)).value);
      expect(values, contains('1280x720'));
      expect(values, contains('1366x768'));
      expect(values.toSet().length, values.length, reason: 'no duplicate dropdown values');
      // A phone whose size equals a preset does not duplicate it
      final dup = DesktopService.resolutionOptions(screen: const Size(412, 915));
      expect(dup.where((r) => r.value == '1600x720').length, 1);
    });

    test('isValidResolution accepts WxH only', () {
      expect(DesktopService.isValidResolution('1280x720'), isTrue);
      expect(DesktopService.isValidResolution('1280x720;id'), isFalse);
      expect(DesktopService.isValidResolution('99999x720'), isFalse);
      expect(DesktopService.isValidResolution('100x100'), isFalse);
    });

    test('installFraction and installProgressText read the guest progress', () {
      final st = {
        'install_state': 'running',
        'install_mode': 'xfce4',
        'install_progress': '50/200',
        'install_step': '( 50/200) Installing gtk+3.0',
      };
      expect(DesktopService.installFraction(st), closeTo(0.25, 1e-9));
      expect(DesktopService.installProgressText(st), contains('xfce4'));
      expect(DesktopService.installProgressText(st), contains('50/200'));
      expect(DesktopService.installFraction({'install_progress': ''}), isNull);
    });

    test('waitForInstall polls until the install ends and reports failures', () async {
      final states = <Map<String, dynamic>>[
        {'install_state': 'running', 'install_progress': '1/10'},
        {}, // VM API did not answer once
        {'install_state': 'running', 'install_progress': '9/10'},
        {'install_state': 'failed', 'install_error': 'apk add failed (exit 1): ERROR: unable to select packages'},
      ];
      final seen = <String>[];
      final res = await DesktopService.waitForInstall(
        interval: Duration.zero,
        fetchStatus: () async => states.removeAt(0),
        onProgress: (st) => seen.add(st['install_progress']?.toString() ?? ''),
      );
      expect(res['install_state'], 'failed');
      expect(res['install_error'], contains('unable to select packages'));
      expect(seen, ['1/10', '9/10', '']);
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

    test('a failed start rethrows the guest error and does not report running', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        if (methodCall.method == 'startDesktop') {
          throw PlatformException(
            code: 'DESKTOP_START_ERROR',
            message: 'x11vnc exited before listening on port 5900',
          );
        }
        if (methodCall.method == 'getDesktopStatus') {
          return {
            'installed': true,
            'running': false,
            'state': 'failed',
            'error': 'x11vnc exited before listening on port 5900',
          };
        }
        return null;
      });
      final vm = VmState();
      await expectLater(
        vm.startDesktop(resolution: '1280x720', wm: 'openbox'),
        throwsA(isA<PlatformException>().having((e) => e.message, 'message', contains('x11vnc'))),
      );
      expect(vm.isDesktopRunning, isFalse);
      expect(vm.isDesktopLoading, isFalse);
      expect(vm.desktopStatus['state'], 'failed');
    });

    test('a start reply without running=true is not treated as success', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        if (methodCall.method == 'startDesktop') {
          return {'status': 'started', 'running': false};
        }
        return null;
      });
      final vm = VmState();
      await vm.startDesktop();
      expect(vm.isDesktopRunning, isFalse);
    });

    test('getDesktopLog passes the log name and line count', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        if (methodCall.method == 'getDesktopLog') return 'state=failed\nerror: Xvfb exited';
        return null;
      });
      final text = await DesktopService.getLog(name: 'all', lines: 50);
      expect(text, contains('Xvfb exited'));
      final call = log.lastWhere((c) => c.method == 'getDesktopLog');
      expect(call.arguments['name'], 'all');
      expect(call.arguments['lines'], 50);
    });
  });
}
