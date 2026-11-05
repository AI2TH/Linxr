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
        cores:         (raw['cores']         as num?)?.toInt() ?? 4,
        totalRamMb:    (raw['totalRamMb']    as num?)?.toInt() ?? 4096,
        freeStorageGb: (raw['freeStorageGb'] as num?)?.toInt() ?? 32,
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

  static Future<bool> hasAllFilesAccess() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('hasAllFilesAccess');
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
    String image,
    String name,
    List<String> cmd, {
    List<Map<String, dynamic>> ports = const [],
    List<Map<String, String>> env = const [],
    String network = 'host',
  }) async {
    try {
      await _channel.invokeMethod('startContainer', {
        'image': image,
        'name': name,
        'cmd': cmd,
        'ports': ports,
        'env': env,
        'network': network,
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

  static Future<void> startExistingContainer(String name) async {
    try {
      await _channel.invokeMethod('startExistingContainer', {'name': name});
    } on PlatformException catch (e) {
      debugPrint("Failed to start existing container: ${e.message}");
      rethrow;
    }
  }

  static Future<void> restartContainer(String name) async {
    try {
      await _channel.invokeMethod('restartContainer', {'name': name});
    } on PlatformException catch (e) {
      debugPrint("Failed to restart container: ${e.message}");
      rethrow;
    }
  }

  static Future<void> deleteContainer(String name) async {
    try {
      await _channel.invokeMethod('deleteContainer', {'name': name});
    } on PlatformException catch (e) {
      debugPrint("Failed to delete container: ${e.message}");
      rethrow;
    }
  }

  static Future<void> updateContainer(
    String name, {
    String? restartPolicy,
    int? memoryMb,
    double? cpus,
  }) async {
    try {
      await _channel.invokeMethod('updateContainer', {
        'name': name,
        if (restartPolicy != null) 'restartPolicy': restartPolicy,
        if (memoryMb != null) 'memoryMb': memoryMb,
        if (cpus != null) 'cpus': cpus,
      });
    } on PlatformException catch (e) {
      debugPrint("Failed to update container: ${e.message}");
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> inspectContainer(String name) async {
    try {
      final result = await _channel.invokeMethod('inspectContainer', {'name': name});
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      debugPrint("Failed to inspect container: ${e.message}");
      rethrow;
    }
  }

  static Future<String> exportContainer(String name) async {
    try {
      final String? result = await _channel.invokeMethod<String>('exportContainer', {'name': name});
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to export container: ${e.message}");
      rethrow;
    }
  }

  static Future<String> importContainer(String name, String file) async {
    try {
      final String? result = await _channel.invokeMethod<String>('importContainer', {
        'name': name,
        'file': file,
      });
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to import container: ${e.message}");
      rethrow;
    }
  }

  static Future<String> saveImage(String image) async {
    try {
      final String? result = await _channel.invokeMethod<String>('saveImage', {'image': image});
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to save image: ${e.message}");
      rethrow;
    }
  }

  static Future<String> loadImage(String file) async {
    try {
      final String? result = await _channel.invokeMethod<String>('loadImage', {'file': file});
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to load image: ${e.message}");
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> listImages() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod('listImages');
      if (result == null) return [];
      return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PlatformException catch (e) {
      debugPrint("Failed to list images: ${e.message}");
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> getPortForwards() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod('getPortForwards');
      if (result == null) return [];
      return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PlatformException catch (e) {
      debugPrint("Failed to get port forwards: ${e.message}");
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> addPortForward(
    int host,
    int guest,
    String desc,
  ) async {
    final List<dynamic>? result = await _channel.invokeMethod('addPortForward', {
      'host': host,
      'guest': guest,
      'desc': desc,
    });
    if (result == null) return [];
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<List<Map<String, dynamic>>> removePortForward(int host) async {
    final List<dynamic>? result = await _channel.invokeMethod('removePortForward', {
      'host': host,
    });
    if (result == null) return [];
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<String> getLanIp() async {
    try {
      final String? result = await _channel.invokeMethod<String>('getLanIp');
      return result ?? '';
    } on PlatformException catch (e) {
      debugPrint("Failed to get LAN IP: ${e.message}");
      return '';
    }
  }

  static Future<Map<String, dynamic>> getContainerEngine() async {
    try {
      final result = await _channel.invokeMethod('getContainerEngine');
      if (result == null) return {'mode': 'fasttrack'};
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      debugPrint("Failed to get container engine: ${e.message}");
      return {'mode': 'fasttrack'};
    }
  }

  static Future<Map<String, dynamic>> setContainerEngine(String mode) async {
    try {
      final result = await _channel.invokeMethod('setContainerEngine', {'mode': mode});
      if (result == null) return {'mode': mode};
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      debugPrint("Failed to set container engine: ${e.message}");
      rethrow;
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

  // ── Virtual Desktop (GUI) ──────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getDesktopStatus() async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod('getDesktopStatus');
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      debugPrint("Failed to getDesktopStatus: ${e.message}");
      return {};
    }
  }

  static Future<Map<String, dynamic>> startDesktop({
    String resolution = '1280x720',
    String wm = 'openbox',
  }) async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod('startDesktop', {
        'resolution': resolution,
        'wm': wm,
      });
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      debugPrint("Failed to startDesktop: ${e.message}");
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> stopDesktop() async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod('stopDesktop');
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      debugPrint("Failed to stopDesktop: ${e.message}");
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> installDesktop({
    String mode = 'lightweight',
  }) async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod('installDesktop', {'mode': mode});
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      debugPrint("Failed to installDesktop: ${e.message}");
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> launchDesktopApp(String app) async {
    try {
      final Map<Object?, Object?>? result =
          await _channel.invokeMethod('launchDesktopApp', {'app': app});
      if (result == null) return {};
      return result.map((k, v) => MapEntry(k.toString(), v));
    } on PlatformException catch (e) {
      debugPrint("Failed to launchDesktopApp: ${e.message}");
      rethrow;
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
  bool _isDesktopRunning = false;
  Map<String, dynamic> _desktopStatus = {};
  bool _isDesktopLoading = false;

  bool get isDesktopRunning => _isDesktopRunning;
  Map<String, dynamic> get desktopStatus => _desktopStatus;
  bool get isDesktopLoading => _isDesktopLoading;

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

  Future<void> refreshDesktopStatus({bool force = false}) async {
    if (!isRunning && !force) {
      if (_isDesktopRunning || _desktopStatus.isNotEmpty) {
        _isDesktopRunning = false;
        _desktopStatus = {};
        notifyListeners();
      }
      return;
    }
    try {
      final res = await VmPlatform.getDesktopStatus();
      final running = res['running'] == true;
      if (running != _isDesktopRunning || res.toString() != _desktopStatus.toString()) {
        _isDesktopRunning = running;
        _desktopStatus = res;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error checking desktop status: $e');
    }
  }

  Future<void> startDesktop({String resolution = '1280x720', String wm = 'openbox'}) async {
    _isDesktopLoading = true;
    notifyListeners();
    try {
      final res = await VmPlatform.startDesktop(resolution: resolution, wm: wm);
      _desktopStatus = res;
      _isDesktopRunning = res['running'] == true || res['status'] == 'started';
    } finally {
      _isDesktopLoading = false;
      notifyListeners();
    }
  }

  Future<void> stopDesktop() async {
    _isDesktopLoading = true;
    notifyListeners();
    try {
      final res = await VmPlatform.stopDesktop();
      _desktopStatus = res;
      _isDesktopRunning = false;
    } finally {
      _isDesktopLoading = false;
      notifyListeners();
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
        if (h) {
          refreshDesktopStatus();
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
    _isDesktopRunning = false;
    _desktopStatus = {};
  }

  @override
  void dispose() {
    _stopPolling();
    _sshPingTimer?.cancel();
    super.dispose();
  }
}
