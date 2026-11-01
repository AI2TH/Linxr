import 'package:flutter_test/flutter_test.dart';
import 'package:linxr/services/vm_platform.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.ai2th.linxr/vm');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (methodCall.method == 'startVm') {
        return null;
      }
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startVm success path updates status and isLoading', () async {
    final vmState = VmState();

    expect(vmState.status, 'stopped');
    expect(vmState.isLoading, false);

    final future = vmState.startVm();

    // During execution
    expect(vmState.status, 'booting');
    expect(vmState.isLoading, true);

    await future;

    // After startVm execution, status is booting until SSH ping succeeds
    expect(vmState.status, 'booting');
    expect(vmState.isLoading, false);
    expect(vmState.errorMessage, isNull);

    expect(log, hasLength(1));
    expect(log[0].method, 'startVm');
  });

  test('getContainerEngine returns engine mode map', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'getContainerEngine') {
        return {'mode': 'fasttrack', 'dockerd_running': false};
      }
      return null;
    });

    final engineInfo = await VmPlatform.getContainerEngine();
    expect(engineInfo['mode'], 'fasttrack');
    expect(engineInfo['dockerd_running'], false);
  });

  test('setContainerEngine invokes platform channel with mode', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'setContainerEngine') {
        capturedCall = methodCall;
        return {'mode': methodCall.arguments['mode'], 'status': 'switched'};
      }
      return null;
    });

    final result = await VmPlatform.setContainerEngine('docker');
    expect(capturedCall?.method, 'setContainerEngine');
    expect(capturedCall?.arguments, {'mode': 'docker'});
    expect(result['mode'], 'docker');
    expect(result['status'], 'switched');
  });
}
