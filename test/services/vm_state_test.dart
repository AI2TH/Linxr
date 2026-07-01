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
    expect(vmState.status, 'starting');
    expect(vmState.isLoading, true);

    await future;

    // After execution
    expect(vmState.status, 'running');
    expect(vmState.isLoading, false);
    expect(vmState.errorMessage, isNull);

    expect(log, hasLength(1));
    expect(log[0].method, 'startVm');
  });
}
