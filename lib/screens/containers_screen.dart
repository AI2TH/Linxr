import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/vm_platform.dart';
import '../theme.dart';

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

class _ContainersScreenState extends State<ContainersScreen> {
  List<ContainerInfo> _containers = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadContainers();
  }

  Future<void> _loadContainers() async {
    if (!mounted) return;
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
            icon: const Icon(Icons.refresh),
            onPressed: _loadContainers,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !vmState.isRunning
              ? _buildVmNotRunningState()
              : _containers.isEmpty
                  ? _buildEmptyState()
                  : _buildContainerList(),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No containers running',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loadContainers,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
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
    final isRunning = container.status.toLowerCase().contains('up');
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
            padding: const EdgeInsets.all(16.0),
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
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _viewLogs(container.name),
                        icon: const Icon(Icons.article, size: 16),
                        label: const Text('Logs', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withOpacity(0.15)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isRunning
                            ? () => _stopContainer(container.name)
                            : null,
                        icon: const Icon(Icons.stop, size: 16),
                        label: const Text('Stop', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.danger,
                          side: BorderSide(color: AppColors.danger.withOpacity(0.4)),
                          disabledForegroundColor: Colors.grey.withOpacity(0.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAddContainerDialog() {
    final imageController = TextEditingController(text: 'busybox');
    final nameController = TextEditingController();
    final cmdController = TextEditingController(text: 'echo hello');

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
                        Navigator.pop(sheetCtx);
                        try {
                          await VmPlatform.startContainer(image, name, cmd);
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

  Future<void> _stopContainer(String name) async {
    try {
      await VmPlatform.stopContainer(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Container stopped')),
        );
        _loadContainers();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error fetching logs: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }
}
