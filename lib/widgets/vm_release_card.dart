import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/vm_platform.dart';
import '../theme.dart';

/// Settings > About: app version plus the Alpine and kernel versions inside
/// the VM, read from /etc/linxr-release through the VM API.
class VmReleaseCard extends StatefulWidget {
  const VmReleaseCard({super.key, required this.appVersion});

  final String appVersion;

  @override
  State<VmReleaseCard> createState() => _VmReleaseCardState();
}

class _VmReleaseCardState extends State<VmReleaseCard> {
  Map<String, dynamic>? _release;
  bool _loading = false;
  bool _wasRunning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final running = context.watch<VmState>().isRunning;
    if (running && !_wasRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetch();
      });
    }
    _wasRunning = running;
  }

  Future<void> _fetch() async {
    if (_loading) return;
    setState(() => _loading = true);
    // The API server can start a little after SSH; retry briefly.
    Map<String, dynamic>? info;
    for (var i = 0; i < 5 && info == null && mounted; i++) {
      info = await VmPlatform.getVmRelease();
      if (info == null) await Future.delayed(const Duration(seconds: 3));
    }
    if (!mounted) return;
    setState(() {
      _release = info ?? _release;
      _loading = false;
    });
  }

  String _value(String key) {
    final v = _release?[key];
    return (v is String && v.isNotEmpty) ? v : '—';
  }

  @override
  Widget build(BuildContext context) {
    final running = context.watch<VmState>().isRunning;
    final release = _release;
    final kernel = release == null
        ? '—'
        : (_value('kernelVersion') != '—' ? _value('kernelVersion') : _value('runningKernel'));

    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row('Linxr app', widget.appVersion.isEmpty ? '—' : 'v${widget.appVersion}'),
            _row('Alpine Linux', release == null ? '—' : _value('alpineVersion')),
            _row('Kernel', kernel),
            if (release != null && _value('buildDate') != '—')
              _row('VM image built', _value('buildDate')),
            const SizedBox(height: 6),
            if (_loading)
              const Text('Reading versions from the VM…',
                  style: TextStyle(color: Colors.white38, fontSize: 11))
            else if (release == null)
              Text(
                running
                    ? 'Could not read versions from the VM API.'
                    : 'Start the VM to see the Alpine and kernel versions.',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              )
            else if (release['hasReleaseFile'] != true)
              const Text(
                'This VM image predates /etc/linxr-release; values come from the running system.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 120,
              child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),
            Expanded(
              child: SelectableText(value,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontFamily: 'monospace')),
            ),
          ],
        ),
      );
}
