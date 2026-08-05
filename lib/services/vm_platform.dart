import 'dart:io';
import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../constants.dart';

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

  static Future<DeviceInfo> getDeviceInfo() async {
    try {
      final Map<Object?, Object?> raw =
          await _channel.invokeMethod('getDeviceInfo');
      return DeviceInfo(
        cores:         (raw['cores']         as int?) ?? 4,
        totalRamMb:    (raw['totalRamMb']    as int?) ?? 4096,
        freeStorageGb: (raw['freeStorageGb'] as int?) ?? 32,
      );
    } on PlatformException {
      return const DeviceInfo(cores: 4, totalRamMb: 4096, freeStorageGb: 32);
    }
  }

  static Future<void> resetStorage() async {
    await _channel.invokeMethod('resetStorage');
  }

  static Future<List<String>> getVmLogs() async {
    try {
      final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>('getVmLogs');
      return raw?.cast<String>() ?? [];
    } on PlatformException {
      return [];
    }
  }

  static Future<void> clearVmLogs() async {
    try {
      await _channel.invokeMethod('clearVmLogs');
    } on PlatformException {
      // ignore
    }
  }

  static Future<bool> requestAllFilesAccess() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('requestAllFilesAccess');
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> pingSsh() async {
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        SshDefaults.host,
        SshDefaults.port,
        timeout: const Duration(seconds: 10),
      );
      client = SSHClient(
        socket,
        username: SshDefaults.username,
        onPasswordRequest: () => SshDefaults.password,
      );
      await client.authenticated.timeout(const Duration(seconds: 25));
      return true;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  static Future<void> startContainer(
      String image, String name, List<String> cmd) async {
    try {
      await _channel.invokeMethod('startContainer', {
        'image': image,
        'name': name,
        'cmd': cmd,
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to start container: ${e.message}");
      rethrow;
    }
  }

  static Future<void> stopContainer(String name) async {
    try {
      await _channel.invokeMethod('stopContainer', {'name': name});
    } on PlatformException catch (e) {
      debugPrint("Failed to stop container: ${e.message}");
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> listContainers() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod('listContainers');
      if (result == null) return [];
      return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PlatformException catch (e) {
      debugPrint("Failed to list containers: ${e.message}");
      return [];
    }
  }

  static Future<Map<String, dynamic>> vmExec(String cmd) async {
    try {
      final result = await _channel.invokeMethod('vmExec', {'cmd': cmd});
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      debugPrint("Failed to vmExec: ${e.message}");
      rethrow;
    }
  }

  static Future<String> getLogs(String name, int tail) async {
    try {
      final String? result = await _channel.invokeMethod<String>('getLogs', {
        'name': name,
        'tail': tail,
      });
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to get logs: ${e.message}");
      return '';
    }
  }

  static Future<bool> checkHealth() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('checkHealth');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint("Failed to check health: ${e.message}");
      return false;
    }
  }
}

class DeviceInfo {
  final int cores;
  final int totalRamMb;
  final int freeStorageGb;
  const DeviceInfo({
    required this.cores,
    required this.totalRamMb,
    required this.freeStorageGb,
  });
}

class VmState extends ChangeNotifier {
  String _status = 'stopped';
  bool _isLoading = false;
  String? _errorMessage;
  bool _isHealthy = false;

  Timer? _pollTimer;
  Timer? _sshPingTimer;
  bool _isPolling = false;

  String get status => _status;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isRunning => _status == 'running';
  bool get isBooting => _status == 'booting';
  bool get isHealthy => _isHealthy;

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

  bool _isPingingSsh = false;

  void _startSshPing() {
    _sshPingTimer?.cancel();
    _sshPingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_status != 'booting') {
        _sshPingTimer?.cancel();
        _sshPingTimer = null;
        return;
      }
      if (_isPingingSsh) return;
      _isPingingSsh = true;
      try {
        final alive = await VmPlatform.pingSsh();
        if (alive) {
          _status = 'running';
          _sshPingTimer?.cancel();
          _sshPingTimer = null;
          _startPolling();
          notifyListeners();
        }
      } finally {
        _isPingingSsh = false;
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
      if (_isPolling) return;
      if (_status != 'running') {
        _stopPolling();
        return;
      }
      _isPolling = true;
      try {
        final s = await VmPlatform.getVmStatus();
        final h = s == 'running' ? await VmPlatform.checkHealth() : false;
        if (s != _status || h != _isHealthy) {
          _status = s;
          _isHealthy = h;
          notifyListeners();
        }
      } finally {
        _isPolling = false;
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isHealthy = false;
  }

  @override
  void dispose() {
    _stopPolling();
    _sshPingTimer?.cancel();
    super.dispose();
  }
}
