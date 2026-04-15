import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class VmPlatform {
  static const _channel = MethodChannel('com.ai2th.linxr/vm');

  static Future<void> startVm() async {
    await _channel.invokeMethod('startVm');
  }

  static Future<void> stopVm() async {
    await _channel.invokeMethod('stopVm');
  }

  static Future<String> getVmStatus() async {
    try {
      final String result = await _channel.invokeMethod('getVmStatus');
      return result;
    } on PlatformException {
      return 'unknown';
    }
  }

  static Future<bool> pingSsh() async {
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        '127.0.0.1',
        2222,
        timeout: const Duration(seconds: 5),
      );
      client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 'alpine',
      );
      await client.authenticated.timeout(const Duration(seconds: 8));
      return true;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }
}

class VmState extends ChangeNotifier {
  String _status = 'stopped';
  bool _isLoading = false;
  String? _errorMessage;

  Timer? _pollTimer;
  Timer? _sshPingTimer;

  String get status => _status;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == 'running';
  bool get isBooting => _status == 'booting';

  Future<void> startVm() async {
    if (_status == 'running' || _status == 'booting' || _status == 'starting') return;
    _isLoading = true;
    _status = 'booting';
    _errorMessage = null;
    notifyListeners();

    try {
      await VmPlatform.startVm();
      _startSshPing();
    } catch (e) {
      _status = 'error';
      _errorMessage = e.toString();
      debugPrint('Error starting VM: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _startSshPing() {
    _sshPingTimer?.cancel();
    _sshPingTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_status != 'booting') {
        _sshPingTimer?.cancel();
        _sshPingTimer = null;
        return;
      }
      final alive = await VmPlatform.pingSsh();
      if (alive) {
        _status = 'running';
        _sshPingTimer?.cancel();
        _sshPingTimer = null;
        _startPolling();
        notifyListeners();
      }
    });
  }

  Future<void> stopVm() async {
    _isLoading = true;
    notifyListeners();
    _stopPolling();
    _sshPingTimer?.cancel();
    _sshPingTimer = null;

    try {
      await VmPlatform.stopVm();
      _status = 'stopped';
      _errorMessage = null;
    } catch (e) {
      _errorMessage = e.toString();
      debugPrint('Error stopping VM: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    try {
      _status = await VmPlatform.getVmStatus();
      if (_status == 'running') {
        _startPolling();
      } else {
        _stopPolling();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing status: $e');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_status != 'running') {
        _stopPolling();
        return;
      }
      final s = await VmPlatform.getVmStatus();
      if (s != _status) {
        _status = s;
        notifyListeners();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    _stopPolling();
    _sshPingTimer?.cancel();
    super.dispose();
  }
}
