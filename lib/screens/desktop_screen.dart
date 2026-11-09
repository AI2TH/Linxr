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

class _DesktopScreenState extends State<DesktopScreen> {
  String _selectedResolution = '1280x720';
  String _selectedWm = 'openbox';
  bool _isActionInProgress = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<VmState>().refreshDesktopStatus();
      }
    });
  }

  Future<void> _startOrInstallDesktop() async {
    final vm = context.read<VmState>();
    if (!vm.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please start the Alpine Linux VM first.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    final status = vm.desktopStatus;
    final isXfce = _selectedWm == 'xfce4' || _selectedWm == 'xfce' || _selectedWm == 'full';
    final isInstalled = isXfce
        ? (status['xfce_installed'] == true)
        : (status['openbox_installed'] == true);

    setState(() {
      _isActionInProgress = true;
      _statusMessage = isInstalled
          ? 'Starting Virtual Desktop server...'
          : 'Installing $_selectedWm desktop packages (this may take 1-2 min)...';
    });

    try {
      if (!isInstalled) {
        await DesktopService.install(mode: _selectedWm);
        await vm.refreshDesktopStatus(force: true);
        if (mounted) {
          setState(() {
            _statusMessage = 'Starting Virtual Desktop server...';
          });
        }
      }

      await vm.startDesktop(
        resolution: _selectedResolution,
        wm: _selectedWm,
      );

      await vm.refreshDesktopStatus(force: true);

      if (mounted) {
        if (vm.isDesktopRunning) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Virtual Desktop started successfully!'),
              backgroundColor: AppColors.secondary,
            ),
          );
        } else {
          final err = vm.desktopStatus['error'] ?? 'Window manager failed to initialize.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Virtual Desktop failed to start: $err'),
              backgroundColor: AppColors.danger,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Virtual Desktop stopped.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to stop desktop: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
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
    final vm = context.read<VmState>();
    if (!vm.isRunning) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please start the Alpine Linux VM first.'),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    setState(() {
      _isActionInProgress = true;
      _statusMessage = 'Installing $mode desktop packages (this may take 1-2 min)...';
    });

    try {
      await DesktopService.install(mode: mode);
      await vm.refreshDesktopStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$mode desktop packages installed successfully!'),
            backgroundColor: AppColors.secondary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Installation failed: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isActionInProgress = false;
          _statusMessage = null;
        });
      }
    }
  }

  Future<void> _launchApp(String appName) async {
    try {
      await DesktopService.launchApp(appName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Launched $appName in Virtual Desktop!'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not launch $appName: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();
    final isVmRunning = vm.isRunning;
    final isDesktopRunning = vm.isDesktopRunning;
    final status = vm.desktopStatus;
    final isXfce = _selectedWm == 'xfce4' || _selectedWm == 'xfce' || _selectedWm == 'full';
    final isSelectedWmInstalled = isXfce
        ? (status['xfce_installed'] == true)
        : (status['openbox_installed'] == true);
    final currentRes = status['resolution'] ?? _selectedResolution;
    final currentWm = status['wm'] ?? _selectedWm;

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
              onPressed: () => DesktopService.launchDesktopExternal(),
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
            ),
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
      statusColor = AppColors.secondary;
      statusTitle = 'Virtual Desktop Active';
      statusSubtitle = '$currentRes · ${currentWm.toUpperCase()} · Port 6080';
      statusIcon = Icons.check_circle;
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
                    ),
                  ),
                ],
              ),
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
                onPressed: _isActionInProgress
                    ? null
                    : () => DesktopService.launchDesktopInApp(context: context),
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
                      onPressed: () => DesktopService.launchDesktopExternal(),
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
                  items: DesktopService.resolutions.map((r) {
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
      {'id': 'calc', 'label': 'Calculator', 'icon': Icons.calculate, 'color': Colors.purpleAccent},
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
                  onTap: () => _launchApp(app['id'] as String),
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
              value: DesktopService.defaultWebUrl,
              hint: 'In-app or Chrome browser view',
              onCopy: () => _copyToClipboard(DesktopService.defaultWebUrl, 'Web URL'),
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
            _buildTipRow('👆 Single Tap', 'Left mouse click & focus application'),
            _buildTipRow('✌️ Two-finger Tap', 'Right click (context menu)'),
            _buildTipRow('🖐️ Pan & Drag', 'Move windows, drag objects, scroll canvas'),
            _buildTipRow('📱 Left Edge Tab', 'Expands noVNC toolbar: On-screen Keyboard, Zoom, Fullscreen'),
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
