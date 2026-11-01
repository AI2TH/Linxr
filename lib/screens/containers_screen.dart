import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/vm_platform.dart';
import '../theme.dart';
import 'marketplace_screen.dart';

class ContainerInfo {
  final String name;
  final String image;
  final String status;
  final List<String> ports;

  ContainerInfo({
    required this.name,
    required this.image,
    required this.status,
    this.ports = const [],
  });

  factory ContainerInfo.fromJson(Map<String, dynamic> json) {
    return ContainerInfo(
      name: json['name'] as String,
      image: json['image'] as String,
      status: json['status'] as String,
      ports: (json['ports'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'image': image,
      'status': status,
      'ports': ports,
    };
  }
}

class ContainersScreen extends StatefulWidget {
  const ContainersScreen({super.key});

  @override
  State<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends State<ContainersScreen> with WidgetsBindingObserver {
  static const _kLanAccess = 'lan_access';
  static const _defaultSharePath = '/storage/emulated/0/LinxrShare';

  List<ContainerInfo> _containers = [];
  bool _isLoading = false;
  bool _hasFilesAccess = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadContainers();
    _checkFilesAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkFilesAccess();
    }
  }

  Future<void> _checkFilesAccess() async {
    final has = await VmPlatform.hasAllFilesAccess();
    if (mounted) setState(() => _hasFilesAccess = has);
  }

  Future<void> _requestFilesAccess() async {
    await VmPlatform.requestAllFilesAccess();
    // The system settings page is opened; re-check on return to app.
    await _checkFilesAccess();
  }

  Future<void> _loadContainers() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final containerMaps = await VmPlatform.listContainers();
      if (!mounted) return;
      setState(() {
        _containers = containerMaps
            .map((map) => ContainerInfo.fromJson(map))
            .toList();
      });
    } catch (e) {
      debugPrint('Error loading containers: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  bool _isRunning(ContainerInfo c) => c.status.toLowerCase().contains('up');

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        backgroundColor: color ?? Colors.grey[800],
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Shows a blocking, non-dismissible progress dialog while [action] runs.
  /// Prevents the UI from looking frozen during slow container operations.
  Future<T> _runWithProgress<T>(String message, Future<T> Function() action) async {
    BuildContext? progressCtx;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        progressCtx = ctx;
        return AlertDialog(
          backgroundColor: AppColors.surface,
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 20),
              Flexible(
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        );
      },
    );
    try {
      return await action();
    } finally {
      if (progressCtx != null && progressCtx!.mounted) {
        Navigator.of(progressCtx!).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vmState = context.watch<VmState>();
    final ready = vmState.isHealthy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Containers'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.lan_outlined),
            tooltip: 'Port forwarding',
            onPressed: _showPortsSheet,
          ),
          IconButton(
            icon: const Icon(Icons.layers_outlined),
            tooltip: 'Images & backup',
            onPressed: _showImagesSheet,
          ),
          IconButton(
            icon: const Icon(Icons.storefront),
            tooltip: 'Marketplace',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MarketplaceScreen()),
              ).then((_) => _loadContainers());
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadContainers,
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_hasFilesAccess) _buildFilesAccessBanner(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : !vmState.isRunning
                    ? _buildVmNotRunningState()
                    : _containers.isEmpty
                        ? _buildEmptyState()
                        : _buildContainerList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: ready ? () => _showAddContainerDialog() : null,
        backgroundColor: ready
            ? AppColors.primary
            : Colors.grey.withOpacity(0.4),
        tooltip: ready ? 'Run container' : 'VM / Docker not ready',
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildFilesAccessBanner() {
    return Container(
      width: double.infinity,
      color: AppColors.warning.withOpacity(0.12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.folder_off, color: AppColors.warning, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Container management needs "All files access" to read/write the shared '
              'folder (export/import and the container API).',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _requestFilesAccess,
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            child: const Text('Grant'),
          ),
        ],
      ),
    );
  }

  Widget _buildVmNotRunningState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.info_outline, size: 64, color: AppColors.warning),
            const SizedBox(height: 16),
            const Text(
              'VM is not running',
              style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Start the Alpine Linux VM from the Home tab to access Docker containers.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No containers running',
              style: TextStyle(fontSize: 18, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const MarketplaceScreen()),
                ).then((_) => _loadContainers());
              },
              icon: const Icon(Icons.storefront, size: 18),
              label: const Text('Browse Marketplace'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loadContainers,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContainerList() {
    return RefreshIndicator(
      onRefresh: _loadContainers,
      child: ListView.builder(
        itemCount: _containers.length,
        itemBuilder: (context, index) {
          final container = _containers[index];
          return _buildContainerCard(container);
        },
      ),
    );
  }

  Widget _buildContainerCard(ContainerInfo container) {
    final isRunning = _isRunning(container);
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ExpansionTile(
        collapsedBackgroundColor: Colors.transparent,
        backgroundColor: Colors.transparent,
        leading: Icon(
          Icons.widgets,
          color: isRunning ? AppColors.secondary : Colors.grey,
        ),
        title: Text(
          container.name,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        subtitle: Text(
          '${container.image} • ${container.status}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        iconColor: Colors.white70,
        collapsedIconColor: Colors.white70,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (container.ports.isNotEmpty) ...[
                  const Text(
                    'Ports:',
                    style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    container.ports.join(', '),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (isRunning)
                      _actionButton('Stop', Icons.stop, () => _stopContainer(container.name),
                          color: AppColors.danger)
                    else
                      _actionButton('Start', Icons.play_arrow, () => _startContainer(container.name),
                          color: AppColors.secondary),
                    _actionButton('Restart', Icons.restart_alt,
                        isRunning ? () => _restartContainer(container.name) : null),
                    _actionButton('Logs', Icons.article, () => _viewLogs(container.name)),
                    _actionButton('Config', Icons.tune, () => _showConfigDialog(container.name)),
                    _actionButton('Export', Icons.file_download, () => _exportContainer(container.name)),
                    _actionButton('Delete', Icons.delete_outline, () => _deleteContainer(container.name),
                        color: AppColors.danger),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(String label, IconData icon, VoidCallback? onPressed, {Color? color}) {
    final c = color ?? Colors.white;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: c,
        side: BorderSide(color: c.withOpacity(0.25)),
        disabledForegroundColor: Colors.grey.withOpacity(0.4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  // ── Container actions ────────────────────────────────────────────────────

  Future<void> _startContainer(String name) async {
    try {
      await _runWithProgress('Starting $name…', () => VmPlatform.startExistingContainer(name));
      _showSnack('Started $name', color: AppColors.secondary);
      _loadContainers();
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _restartContainer(String name) async {
    try {
      await _runWithProgress('Restarting $name…', () => VmPlatform.restartContainer(name));
      _showSnack('Restarted $name', color: AppColors.secondary);
      _loadContainers();
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _stopContainer(String name) async {
    try {
      await _runWithProgress('Stopping $name…', () => VmPlatform.stopContainer(name));
      _showSnack('Container stopped');
      _loadContainers();
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _deleteContainer(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete Container', style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "$name"? This force-removes the container (and its writable layer).',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _runWithProgress('Deleting $name…', () => VmPlatform.deleteContainer(name));
      _showSnack('Deleted $name');
      _loadContainers();
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _exportContainer(String name) async {
    try {
      final file = await _runWithProgress(
        'Exporting $name… (may take a while)',
        () => VmPlatform.exportContainer(name),
      );
      if (!mounted) return;
      _showSnack(
        'Exported to $_defaultSharePath/linxr-exports/$file',
        color: AppColors.secondary,
      );
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _viewLogs(String name) async {
    try {
      final logs = await VmPlatform.getLogs(name, 100);
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text('Logs: $name', style: const TextStyle(color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Text(
                  logs.isEmpty ? 'No logs available' : logs,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      _showSnack('Error fetching logs: $e', color: AppColors.danger);
    }
  }

  // ── Config edit (docker update) ──────────────────────────────────────────

  Future<void> _showConfigDialog(String name) async {
    Map<String, dynamic> info;
    try {
      info = await VmPlatform.inspectContainer(name);
    } catch (e) {
      _showSnack('Failed to inspect: $e', color: AppColors.danger);
      return;
    }

    final restartController = TextEditingController(
      text: (info['restartPolicy'] as String?) ?? 'no',
    );
    final memoryController = TextEditingController(
      text: (info['memoryMb'] is num && (info['memoryMb'] as num) > 0)
          ? '${(info['memoryMb'] as num).toInt()}'
          : '',
    );
    final cpusController = TextEditingController(
      text: (info['cpus'] is num && (info['cpus'] as num) > 0)
          ? '${info['cpus']}'
          : '',
    );

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Configure Container',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Image: ${info['image'] ?? ''}  (applied via docker update, restart policy/resources)',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _dialogDropdown(
                label: 'Restart policy',
                value: restartController.text,
                options: const ['no', 'always', 'on-failure', 'unless-stopped'],
                onChanged: (v) => restartController.text = v,
              ),
              const SizedBox(height: 12),
              _dialogField(memoryController, 'Memory limit (MB)', 'e.g. 512 (empty = unlimited)'),
              const SizedBox(height: 12),
              _dialogField(cpusController, 'CPU limit (cores)', 'e.g. 1.5 (empty = unlimited)'),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetCtx),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white60,
                        side: BorderSide(color: Colors.white.withOpacity(0.15)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () async {
                        Navigator.pop(sheetCtx);
                        final restartPolicy = restartController.text.trim();
                        final memoryMb = int.tryParse(memoryController.text.trim());
                        final cpus = double.tryParse(cpusController.text.trim());
                        try {
                          await _runWithProgress('Applying config…', () => VmPlatform.updateContainer(
                                name,
                                restartPolicy: restartPolicy.isEmpty ? null : restartPolicy,
                                memoryMb: memoryMb,
                                cpus: cpus,
                              ));
                          _showSnack('Config updated', color: AppColors.secondary);
                          _loadContainers();
                        } catch (e) {
                          _showSnack('Error: $e', color: AppColors.danger);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Port forwarding (LAN access) ─────────────────────────────────────────

  Future<void> _showPortsSheet() async {
    final lanIp = await VmPlatform.getLanIp();
    List<Map<String, dynamic>> ports = await VmPlatform.getPortForwards();
    final prefs = await SharedPreferences.getInstance();
    var lanAccess = prefs.getBool(_kLanAccess) ?? false;
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Port Forwarding',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add, color: AppColors.primary),
                        tooltip: 'Add custom port',
                        onPressed: () async {
                          final added = await _showAddPortDialog();
                          if (added == null) return;
                          try {
                            ports = await VmPlatform.addPortForward(
                              added['host'] as int,
                              added['guest'] as int,
                              added['desc'] as String,
                            );
                            setSheetState(() {});
                            _showSnack('Port added — restart VM to apply', color: AppColors.secondary);
                          } catch (e) {
                            _showSnack('Error: $e', color: AppColors.danger);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.wifi, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          lanIp.isEmpty ? 'LAN IP: not connected' : 'LAN IP: $lanIp',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                      if (lanIp.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
                          tooltip: 'Copy IP',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: lanIp));
                            _showSnack('Copied $lanIp');
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Containers run with host networking, so their ports live on the VM. '
                    'These forwards map the phone to the VM.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow LAN access',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                    subtitle: const Text(
                      'Bind forwards to 0.0.0.0 so other devices on your Wi-Fi can reach them. '
                      'Takes effect on next VM start.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    value: lanAccess,
                    activeColor: AppColors.primary,
                    onChanged: (v) async {
                      setSheetState(() => lanAccess = v);
                      await prefs.setBool(_kLanAccess, v);
                    },
                  ),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final p in ports)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.arrow_forward, size: 16, color: Colors.white38),
                            title: Text(
                              '${p['host']} → ${p['guest']}',
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace'),
                            ),
                            subtitle: Text(
                              '${p['desc'] ?? ''}',
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                            trailing: (p['custom'] == true)
                                ? IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
                                    tooltip: 'Remove',
                                    onPressed: () async {
                                      try {
                                        ports = await VmPlatform.removePortForward((p['host'] as num).toInt());
                                        setSheetState(() {});
                                        _showSnack('Port removed — restart VM to apply', color: AppColors.secondary);
                                      } catch (e) {
                                        _showSnack('Error: $e', color: AppColors.danger);
                                      }
                                    },
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'New ports take effect on next VM start.',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) => setState(() {}));
  }

  Future<Map<String, dynamic>?> _showAddPortDialog() async {
    final hostController = TextEditingController();
    final guestController = TextEditingController();
    final descController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Add Port Forward', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogField(hostController, 'Host port', 'e.g. 8085 (phone port)'),
            const SizedBox(height: 12),
            _dialogField(guestController, 'Guest port', 'e.g. 80 (port inside VM)'),
            const SizedBox(height: 12),
            _dialogField(descController, 'Description', 'e.g. myapp'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;

    final host = int.tryParse(hostController.text.trim());
    final guest = int.tryParse(guestController.text.trim());
    if (host == null || guest == null || host < 1 || host > 65535 || guest < 1 || guest > 65535) {
      _showSnack('Ports must be within 1-65535', color: AppColors.danger);
      return null;
    }
    final desc = descController.text.trim();
    return {'host': host, 'guest': guest, 'desc': desc.isEmpty ? 'Custom' : desc};
  }

  // ── Images & backup (save/load) ──────────────────────────────────────────

  Future<void> _showImagesSheet() async {
    List<Map<String, dynamic>> images;
    try {
      images = await VmPlatform.listImages();
    } catch (e) {
      _showSnack('Failed to list images: $e', color: AppColors.danger);
      return;
    }
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Images & Backup',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Export/import Docker images as .tar files in the shared folder.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _showLoadImageDialog();
                      },
                      icon: const Icon(Icons.file_upload, size: 18),
                      label: const Text('Load image'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        _showImportContainerDialog();
                      },
                      icon: const Icon(Icons.archive, size: 18),
                      label: const Text('Import container'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withOpacity(0.2)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Images', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              if (images.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No images found', style: TextStyle(color: Colors.white38, fontSize: 13)),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final img in images)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${img['repoTag'] ?? img['id'] ?? ''}',
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _fmtBytes((img['size'] as num?)?.toInt() ?? 0),
                            style: const TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                          trailing: TextButton.icon(
                            onPressed: (img['repoTag'] as String?)?.isEmpty == false
                                ? () {
                                    Navigator.pop(sheetCtx);
                                    _saveImage(img['repoTag'] as String);
                                  }
                                : null,
                            icon: const Icon(Icons.file_download, size: 16),
                            label: const Text('Save', style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ).then((_) {
      setState(() {});
      _loadContainers();
    });
  }

  Future<void> _saveImage(String image) async {
    try {
      final file = await _runWithProgress(
        'Saving image $image… (may take a while)',
        () => VmPlatform.saveImage(image),
      );
      _showSnack('Saved to $_defaultSharePath/linxr-exports/$file', color: AppColors.secondary);
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _showLoadImageDialog() async {
    final fileController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Load Image', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: fileController,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'image.tar (in shared folder)',
            hintStyle: TextStyle(color: Colors.white24),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, fileController.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Load'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      await _runWithProgress('Loading image (may take a while)…', () => VmPlatform.loadImage(result));
      _showSnack('Image loaded', color: AppColors.secondary);
    } catch (e) {
      _showSnack('Error: $e', color: AppColors.danger);
    }
  }

  Future<void> _showImportContainerDialog() async {
    final nameController = TextEditingController();
    final fileController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import Container Snapshot',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Creates a new image from a container export .tar file in the shared folder.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _dialogField(fileController, 'Tar file', 'e.g. mycontainer.tar'),
              const SizedBox(height: 12),
              _dialogField(nameController, 'New image name', 'e.g. myapp:latest'),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetCtx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () async {
                        final name = nameController.text.trim();
                        final file = fileController.text.trim();
                        Navigator.pop(sheetCtx);
                        if (name.isEmpty || file.isEmpty) {
                          _showSnack('Name and file required', color: AppColors.danger);
                          return;
                        }
                        _showSnack('Importing…');
                        try {
                          await _runWithProgress('Importing (may take a while)…',
                              () => VmPlatform.importContainer(name, file));
                          _showSnack('Imported as image $name', color: AppColors.secondary);
                        } catch (e) {
                          _showSnack('Error: $e', color: AppColors.danger);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Import', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Run-container dialog (unchanged behaviour) ───────────────────────────

  void _showAddContainerDialog() {
    final imageController = TextEditingController(text: 'busybox');
    final nameController = TextEditingController();
    final cmdController = TextEditingController(text: 'echo hello');
    final portController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Run Container',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              _dialogField(imageController, 'Image', 'e.g., busybox, nginx:alpine'),
              const SizedBox(height: 12),
              _dialogField(nameController, 'Name (optional)', 'Auto-generated if empty'),
              const SizedBox(height: 12),
              _dialogField(cmdController, 'Command', 'e.g., echo hello'),
              const SizedBox(height: 12),
              _dialogField(portController, 'Port Mapping (optional)', 'e.g., 8080:80'),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(sheetCtx),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white60,
                        side: BorderSide(color: Colors.white.withOpacity(0.15)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () async {
                        final image = imageController.text.trim();
                        final name = nameController.text.trim().isEmpty
                            ? 'container_${DateTime.now().millisecondsSinceEpoch}'
                            : nameController.text.trim();
                        final cmd = cmdController.text.trim().split(' ')
                            .where((s) => s.isNotEmpty)
                            .toList();

                        List<Map<String, dynamic>> ports = [];
                        if (portController.text.trim().contains(':')) {
                          final parts = portController.text.trim().split(':');
                          final hostPort = int.tryParse(parts[0]);
                          final containerPort = int.tryParse(parts[1]);
                          if (hostPort != null && containerPort != null) {
                            ports.add({'host': hostPort, 'container': containerPort});
                          }
                        }

                        Navigator.pop(sheetCtx);
                        try {
                          await _runWithProgress('Starting $image…',
                              () => VmPlatform.startContainer(image, name, cmd, ports: ports));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Started $image'),
                                backgroundColor: AppColors.secondary.withOpacity(0.9),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            _loadContainers();
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error: $e',
                                    style: const TextStyle(fontSize: 12)),
                                backgroundColor: AppColors.danger.withOpacity(0.9),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: const Text('Run',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogField(TextEditingController ctrl, String label, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 13),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }

  Widget _dialogDropdown({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: DropdownButton<String>(
            value: options.contains(value) ? value : options.first,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: AppColors.surface,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            items: options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '';
    double size = bytes.toDouble();
    int unit = 0;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(1)} ${units[unit]}';
  }
}