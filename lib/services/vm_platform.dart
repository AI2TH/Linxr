import 'dart:async';
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
}

class VmState extends ChangeNotifier {
  String _status = 'stopped';
  bool _isLoading = false;
  String? _errorMessage;

  Timer? _pollTimer;

  String get status => _status;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == 'running';

  Future<void> startVm() async {
    if (_status == 'running' || _status == 'starting') return;
    _isLoading = true;
    _status = 'starting';
    _errorMessage = null;
    notifyListeners();

    try {
      await VmPlatform.startVm();
      _status = 'running';
      _startPolling();
    } catch (e) {
      _status = 'error';
      _errorMessage = e.toString();
      debugPrint('Error starting VM: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> stopVm() async {
    _isLoading = true;
    notifyListeners();
    _stopPolling();

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
      if (_status != 'running' && _status != 'starting') {
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
    super.dispose();
  }
}
