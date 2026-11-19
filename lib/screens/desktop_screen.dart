import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/desktop_service.dart';
import '../services/vm_platform.dart';
import '../theme.dart';

class DesktopScreen extends StatefulWidget {
  const DesktopScreen({super.key});

  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen> with WidgetsBindingObserver {
  String _selectedResolution = '1280x720';
  String _selectedWm = 'openbox';
  bool _isActionInProgress = false;
  String? _statusMessage;
  // Install progress 0..1 while packages are being installed.
  double? _installFraction;
  // Last start/install/app failure, shown until dismissed or a later success.
  String? _lastError;
  // Take the resolution and environment of the last session from the guest
  // once, instead of always showing the defaults.
  bool _selectionFromStatus = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await context.read<VmState>().refreshDesktopStatus();
      _adoptStatusSelection();
      _resumeInstallIfRunning();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the noVNC tab or from the background: the desktop may
    // have stopped meanwhile, so show its real state.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<VmState>().refreshDesktopStatus();
    }
  }

  void _adoptStatusSelection() {
    if (_selectionFromStatus || !mounted) return;
    final status = context.read<VmState>().desktopStatus;
    if (status.isEmpty) return;
    _selectionFromStatus = true;
    final res = status['resolution']?.toString() ?? '';
    final wm = status['wm']?.toString() ?? '';
    setState(() {
      if (DesktopService.isValidResolution(res)) _selectedResolution = res;
      if (DesktopService.windowManagers.any((w) => w.value == wm)) _selectedWm = wm;
    });
  }

  // An install started earlier (or from another screen) is still running:
  // follow it instead of offering a second one.
  Future<void> _resumeInstallIfRunning() async {
    if (!mounted || _isActionInProgress) return;
    final status = context.read<VmState>().desktopStatus;
    if (status['install_state'] != 'running') return;
    setState(() => _isActionInProgress = true);
    try {
      await _followInstall();
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
          _installFraction = null;
        });
      }
    }
  }

  String _errorText(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString();
  }

  void _showSnack(String text, {Color? color, Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  bool _vmReady() {
    if (context.read<VmState>().isRunning) return true;
    _showSnack('Please start the Alpine Linux VM first.', color: AppColors.warning);
    return false;
  }

  /// Polls the running install until it ends. Returns true if it succeeded.
  Future<bool> _followInstall() async {
    final vm = context.read<VmState>();
    final status = await DesktopService.waitForInstall(onProgress: (st) {
      if (!mounted) return;
      setState(() {
        _statusMessage = DesktopService.installProgressText(st);
        _installFraction = DesktopService.installFraction(st);
      });
    });
    await vm.refreshDesktopStatus(force: true);
    final state = status['install_state']?.toString();
    if (state == 'ok') return true;
    if (mounted) {
      setState(() {
        _lastError = state == 'running'
            ? 'The install is still running after 45 minutes. Check the desktop log.'
            : 'Install failed: ${status['install_error'] ?? 'unknown error'}';
      });
    }
    return false;
  }

  /// Starts the package install and follows it. Returns true on success.
  Future<bool> _runInstall(String mode) async {
    setState(() {
      _statusMessage = 'Starting the $mode package install...';
      _installFraction = null;
      _lastError = null;
    });
    try {
      final res = await DesktopService.install(mode: mode);
      if (!mounted) return false;
      if (res['install_state'] == 'ok') {
        await context.read<VmState>().refreshDesktopStatus(force: true);
        return true;
      }
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Install failed: ${_errorText(e)}');
      return false;
    }
    if (!mounted) return false;
    return _followInstall();
  }

  Future<void> _startOrInstallDesktop() async {
    if (!_vmReady()) return;
    final vm = context.read<VmState>();
    final status = vm.desktopStatus;
    final isXfce = _selectedWm == 'xfce4';
    final isInstalled = isXfce
        ? (status['xfce_installed'] == true)
        : (status['openbox_installed'] == true);

    setState(() {
      _isActionInProgress = true;
      _lastError = null;
    });

    try {
      if (!isInstalled) {
        if (!await _runInstall(_selectedWm)) return;
      }
      if (!mounted) return;
      setState(() {
        _installFraction = null;
        _statusMessage = 'Starting the desktop: Xvfb, ${isXfce ? 'XFCE4' : 'Openbox'}, '
            'x11vnc and noVNC. This can take a minute under emulation...';
      });

      await vm.startDesktop(
        resolution: _selectedResolution,
        wm: _selectedWm,
      );

      if (!mounted) return;
      if (vm.isDesktopRunning) {
        _showSnack('Virtual Desktop is running.', color: AppColors.secondary);
      } else {
        setState(() {
          _lastError = vm.desktopStatus['error']?.toString().isNotEmpty == true
              ? vm.desktopStatus['error'].toString()
              : 'The desktop did not report all components running.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Desktop failed to start: ${_errorText(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
          _installFraction = null;
        });
      }
    }
  }

  Future<void> _stopDesktop() async {
    final vm = context.read<VmState>();
    setState(() {
      _isActionInProgress = true;
      _statusMessage = 'Stopping Virtual Desktop...';
    });

    try {
      await vm.stopDesktop();
      if (mounted) setState(() => _lastError = null);
      _showSnack('Virtual Desktop stopped.');
    } catch (e) {
      if (mounted) setState(() => _lastError = 'Failed to stop the desktop: ${_errorText(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
        });
      }
    }
  }

  Future<void> _installDesktop(String mode) async {
    if (!_vmReady()) return;
    setState(() => _isActionInProgress = true);
    try {
      if (await _runInstall(mode)) {
        _showSnack('$mode desktop packages installed.', color: AppColors.secondary);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
          _installFraction = null;
        });
      }
    }
  }

  /// Opens noVNC only if the desktop is really up, so the user never lands
  /// on a "Failed to connect to server" page without an explanation.
  Future<void> _openViewer({bool external = false}) async {
    final vm = context.read<VmState>();
    await vm.refreshDesktopStatus(force: true);
    if (!mounted) return;
    if (!vm.isDesktopRunning) {
      final err = vm.desktopStatus['error']?.toString() ?? '';
      setState(() {
        _lastError = err.isNotEmpty
            ? 'The desktop is not running: $err'
            : 'The desktop is not running any more. Start it again.';
      });
      return;
    }
    final port = (vm.desktopStatus['web_port'] as num?)?.toInt() ?? DesktopService.defaultWebPort;
    if (external) {
      await DesktopService.launchDesktopExternal(port: port);
    } else {
      await DesktopService.launchDesktopInApp(port: port, context: context);
    }
  }

  Future<void> _launchApp(String appId, String label) async {
    try {
      await DesktopService.launchApp(appId);
      _showSnack('Opened $label in the Virtual Desktop.', duration: const Duration(seconds: 2));
    } catch (e) {
      _showSnack('Could not open $label: ${_errorText(e)}', color: AppColors.danger);
    }
  }

  Future<void> _showLog() async {
    String text = 'Loading...';
    var loading = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          Future<void> load() async {
            if (loading) return;
            loading = true;
            String result;
            try {
              result = await DesktopService.getLog(name: 'all', lines: 300);
            } catch (e) {
              result = 'Could not read the desktop log: ${_errorText(e)}';
            }
            loading = false;
            if (ctx.mounted) setDialogState(() => text = result);
          }

          if (text == 'Loading...' && !loading) load();
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('Virtual Desktop log', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Desktop log copied'), duration: Duration(seconds: 2)),
                  );
                },
                child: const Text('Copy'),
              ),
              TextButton(
                onPressed: () {
                  setDialogState(() => text = 'Loading...');
                },
                child: const Text('Refresh'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        });
      },
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildErrorCard({required String message, required bool isWarning}) {
    final color = isWarning ? AppColors.warning : AppColors.danger;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(isWarning ? Icons.warning_amber_rounded : Icons.error_outline, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.article_outlined, size: 16),
                label: const Text('View desktop log'),
                onPressed: _showLog,
              ),
              if (_lastError != null)
                TextButton(
                  onPressed: () => setState(() => _lastError = null),
                  child: const Text('Dismiss'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();
    final isVmRunning = vm.isRunning;
    final isDesktopRunning = vm.isDesktopRunning;
    final status = vm.desktopStatus;
    final isXfce = _selectedWm == 'xfce4';
    final isSelectedWmInstalled = isXfce
        ? (status['xfce_installed'] == true)
        : (status['openbox_installed'] == true);
    final currentRes = status['resolution'] ?? _selectedResolution;
    final currentWm = status['wm'] ?? _selectedWm;
    final webPort = (status['web_port'] as num?)?.toInt() ?? DesktopService.defaultWebPort;
    final desktopState = status['state']?.toString() ?? '';
    final statusError = status['error']?.toString() ?? '';
    // A failure recorded by the guest (for example Xvfb crashed while the
    // app was in the background) is shown even if this screen did not start it.
    final String? errorMessage = _lastError ??
        (isVmRunning && statusError.isNotEmpty && (desktopState == 'failed' || desktopState == 'degraded')
            ? (desktopState == 'degraded'
                ? 'The desktop is degraded: $statusError'
                : 'The desktop stopped: $statusError')
            : null);
    if (!_selectionFromStatus && status.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _adoptStatusSelection());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.desktop_windows, size: 22, color: AppColors.primary),
            SizedBox(width: 8),
            Text('Virtual Desktop (GUI)'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Status',
            onPressed: isVmRunning
                ? () => vm.refreshDesktopStatus(force: true)
                : null,
          ),
          if (isDesktopRunning)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open in External Browser',
              onPressed: () => _openViewer(external: true),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Hero Card
            _buildHeroCard(
              context: context,
              isVmRunning: isVmRunning,
              isDesktopRunning: isDesktopRunning,
              isSelectedWmInstalled: isSelectedWmInstalled,
              selectedWm: _selectedWm,
              currentRes: currentRes.toString(),
              currentWm: currentWm.toString(),
              desktopState: desktopState,
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 12),
              _buildErrorCard(
                message: errorMessage,
                isWarning: _lastError == null && desktopState == 'degraded',
              ),
            ],
            const SizedBox(height: 16),

            // Display Configuration
            _buildConfigCard(
              context: context,
              isDesktopRunning: isDesktopRunning,
              isVmRunning: isVmRunning,
              isSelectedWmInstalled: isSelectedWmInstalled,
              currentWm: currentWm.toString(),
            ),
            const SizedBox(height: 16),

            // Quick App Launchers (when running)
            if (isDesktopRunning) ...[
              _buildQuickAppsCard(context),
              const SizedBox(height: 16),
            ],

            // Connection Details
            _buildConnectionCard(
              context: context,
              isDesktopRunning: isDesktopRunning,
              webPort: webPort,
            ),
            const SizedBox(height: 16),

            // Mobile Gesture & Touch Guide
            _buildTouchGuideCard(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroCard({
    required BuildContext context,
    required bool isVmRunning,
    required bool isDesktopRunning,
    required bool isSelectedWmInstalled,
    required String selectedWm,
    required String currentRes,
    required String currentWm,
    required String desktopState,
  }) {
    Color statusColor;
    String statusTitle;
    String statusSubtitle;
    IconData statusIcon;

    if (!isVmRunning) {
      statusColor = Colors.white38;
      statusTitle = 'VM Stopped';
      statusSubtitle = 'Start Alpine Linux VM to enable the Virtual Desktop.';
      statusIcon = Icons.power_settings_new;
    } else if (isDesktopRunning) {
      statusColor = desktopState == 'degraded' ? AppColors.warning : AppColors.secondary;
      statusTitle = desktopState == 'degraded' ? 'Virtual Desktop Degraded' : 'Virtual Desktop Active';
      statusSubtitle = '$currentRes · ${currentWm.toUpperCase()} · Port 6080';
      statusIcon = Icons.check_circle;
    } else if (desktopState == 'starting' || desktopState == 'degraded') {
      statusColor = AppColors.warning;
      statusTitle = desktopState == 'starting' ? 'Desktop Starting' : 'Desktop Recovering';
      statusSubtitle = 'Waiting for every component to come up...';
      statusIcon = Icons.hourglass_top;
    } else if (isSelectedWmInstalled) {
      statusColor = AppColors.warning;
      statusTitle = 'Desktop Stopped';
      statusSubtitle = 'Packages ready. Tap Start to boot your GUI.';
      statusIcon = Icons.desktop_access_disabled;
    } else {
      statusColor = Colors.blueAccent;
      statusTitle = 'Ready to Install';
      statusSubtitle = 'One-click install ${selectedWm.toUpperCase()} desktop.';
      statusIcon = Icons.download;
    }

    return Card(
      color: AppColors.surface,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isDesktopRunning ? AppColors.secondary.withOpacity(0.4) : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(statusIcon, color: statusColor, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        statusSubtitle,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: const TextStyle(color: AppColors.primary, fontSize: 13),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (_installFraction != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _installFraction,
                  color: AppColors.primary,
                  backgroundColor: Colors.white12,
                ),
              ],
            ],
            const SizedBox(height: 20),

            // Primary Action Buttons
            if (isDesktopRunning) ...[
              ElevatedButton.icon(
                icon: const Icon(Icons.touch_app, size: 20),
                label: const Text(
                  '🚀 Launch Virtual Desktop (In-App)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isActionInProgress ? null : () => _openViewer(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('External Browser'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: Colors.white.withOpacity(0.2)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _isActionInProgress ? null : () => _openViewer(external: true),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.stop_circle_outlined, size: 18, color: AppColors.danger),
                      label: const Text('Stop Desktop', style: TextStyle(color: AppColors.danger)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: AppColors.danger.withOpacity(0.4)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _isActionInProgress ? null : _stopDesktop,
                    ),
                  ),
                ],
              ),
            ] else ...[
              ElevatedButton.icon(
                icon: Icon(
                  isSelectedWmInstalled ? Icons.play_arrow_rounded : Icons.download_rounded,
                  size: 22,
                ),
                label: Text(
                  isSelectedWmInstalled ? 'Start Virtual Desktop' : 'Install & Start Desktop',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isVmRunning ? AppColors.primary : Colors.white12,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: (isVmRunning && !_isActionInProgress) ? _startOrInstallDesktop : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfigCard({
    required BuildContext context,
    required bool isDesktopRunning,
    required bool isVmRunning,
    required bool isSelectedWmInstalled,
    required String currentWm,
  }) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, size: 20, color: AppColors.primary),
                SizedBox(width: 8),
                Text(
                  'Display & Environment Settings',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Resolution Selector
            const Text(
              'Canvas Resolution',
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedResolution,
                  isExpanded: true,
                  dropdownColor: AppColors.surface,
                  items: DesktopService.resolutionOptions(
                    screen: MediaQuery.of(context).size,
                    current: _selectedResolution,
                  ).map((r) {
                    return DropdownMenuItem<String>(
                      value: r.value,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(r.label, style: const TextStyle(color: Colors.white, fontSize: 14)),
                          Text(r.description, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: isDesktopRunning
                      ? null
                      : (val) {
                          if (val != null) setState(() => _selectedResolution = val);
                        },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Window Manager Selector
            const Text(
              'Desktop Environment',
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: DesktopService.windowManagers.map((wm) {
                final isSelected = isDesktopRunning ? (currentWm == wm.value) : (_selectedWm == wm.value);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: isDesktopRunning
                          ? null
                          : () => setState(() => _selectedWm = wm.value),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected ? AppColors.primary.withOpacity(0.2) : AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected ? AppColors.primary : Colors.white12,
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(wm.icon, style: const TextStyle(fontSize: 16)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    wm.label,
                                    style: TextStyle(
                                      color: isSelected ? Colors.white : Colors.white70,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              wm.description,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 10,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            if (!isDesktopRunning)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: Text(
                    isSelectedWmInstalled
                        ? 'Reinstall $_selectedWm packages'
                        : 'Pre-install $_selectedWm packages',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: (isVmRunning && !_isActionInProgress)
                      ? () => _installDesktop(_selectedWm)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickAppsCard(BuildContext context) {
    final apps = [
      {'id': 'terminal', 'label': 'Terminal', 'icon': Icons.terminal, 'color': AppColors.primary},
      {'id': 'files', 'label': 'File Manager', 'icon': Icons.folder_open, 'color': Colors.amber},
      {'id': 'editor', 'label': 'Text Editor', 'icon': Icons.edit_note, 'color': Colors.greenAccent},
      {'id': 'calculator', 'label': 'Calculator', 'icon': Icons.calculate, 'color': Colors.purpleAccent},
    ];

    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.apps, size: 20, color: AppColors.primary),
                SizedBox(width: 8),
                Text(
                  'Launch GUI Apps in Desktop',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: apps.map((app) {
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _launchApp(app['id'] as String, app['label'] as String),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: (app['color'] as Color).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            app['icon'] as IconData,
                            color: app['color'] as Color,
                            size: 26,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          app['label'] as String,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
                      ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard({
    required BuildContext context,
    required bool isDesktopRunning,
    required int webPort,
  }) {
    final webUrl = DesktopService.buildViewerUri(port: webPort).toString();
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.link, size: 20, color: AppColors.primary),
                SizedBox(width: 8),
                Text(
                  'Connection & Access Endpoints',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildConnectionRow(
              label: 'Web noVNC URL',
              value: webUrl,
              hint: 'In-app or Chrome browser view',
              onCopy: () => _copyToClipboard(webUrl, 'Web URL'),
            ),
            const Divider(color: Colors.white10, height: 20),
            _buildConnectionRow(
              label: 'Native VNC Server',
              value: DesktopService.vncAddress,
              hint: 'Connect via bVNC, AVNC, RealVNC (no password)',
              onCopy: () => _copyToClipboard(DesktopService.vncAddress, 'VNC Address'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionRow({
    required String label,
    required String value,
    required String hint,
    required VoidCallback onCopy,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(color: AppColors.primary, fontSize: 12, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
              Text(hint, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18, color: Colors.white54),
          tooltip: 'Copy',
          onPressed: onCopy,
        ),
      ],
    );
  }

  Widget _buildTouchGuideCard(BuildContext context) {
    return Card(
      color: AppColors.surface.withOpacity(0.6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.touch_app_outlined, size: 18, color: Colors.white70),
                SizedBox(width: 8),
                Text(
                  'Phone Touchscreen Tips',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildTipRow('👆 Tap', 'Left click (double-tap to double-click)'),
            _buildTipRow('✌️ Two-finger tap', 'Right click (context / Openbox menu)'),
            _buildTipRow('👇 Long press', 'Right click and hold'),
            _buildTipRow('🖐️ Drag', 'Move windows, select text, drag files'),
            _buildTipRow('↕️ Two-finger drag', 'Scroll'),
            _buildTipRow('⌨️ Left-edge tab', 'noVNC toolbar: keyboard icon opens the phone keyboard; also clipboard, Ctrl/Alt/Esc keys and fullscreen'),
            _buildTipRow('🔄 Back in the app', 'The viewer reconnects by itself; if the desktop stopped, this screen shows why'),
          ],
        ),
      ),
    );
  }

  Widget _buildTipRow(String gesture, String action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              gesture,
              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
