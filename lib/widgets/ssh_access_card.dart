import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../services/ssh_credentials.dart';
import '../services/vm_platform.dart';
import '../theme.dart';

/// Settings card with the per-install SSH login: user, port, the root
/// password (hidden until revealed, with a copy button) and the key-only
/// login switch.
class SshAccessCard extends StatefulWidget {
  const SshAccessCard({super.key});

  /// SharedPreferences key read by VmManager.kt as "flutter.ssh_key_only".
  static const prefKeyOnly = 'ssh_key_only';

  @override
  State<SshAccessCard> createState() => _SshAccessCardState();
}

class _SshAccessCardState extends State<SshAccessCard> {
  SshCredentials? _creds;
  bool _keyOnlyPref = false;
  bool _reveal = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      SshCredentials.load(refresh: true),
      SharedPreferences.getInstance(),
    ]);
    if (!mounted) return;
    setState(() {
      _creds = results[0] as SshCredentials;
      _keyOnlyPref = (results[1] as SharedPreferences).getBool(SshAccessCard.prefKeyOnly) ?? false;
    });
  }

  void _copyPassword() {
    final pw = _creds?.password;
    if (pw == null) return;
    Clipboard.setData(ClipboardData(text: pw));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Root password copied'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _setKeyOnly(bool enable, VmState vm) async {
    final messenger = ScaffoldMessenger.of(context);
    if (enable) {
      if (!vm.isRunning) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Start the VM first: the app creates its SSH key inside the VM.'),
        ));
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Key-only SSH login?', style: TextStyle(color: Colors.white)),
          content: const Text(
            'The app creates an SSH key in the VM and keeps the private key in '
            'Android Keystore. From the next VM start, root can no longer log '
            'in with a password.\n\n'
            'Other SSH clients (for example a laptop on your Wi-Fi) then need '
            'their own public key in /root/.ssh/authorized_keys.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enable')),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      if (enable) await SshCredentials.createKey();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(SshAccessCard.prefKeyOnly, enable);
      await _load();
      messenger.showSnackBar(SnackBar(
        content: Text(enable
            ? 'App key created. Password login is disabled from the next VM start.'
            : 'Password login is enabled again from the next VM start.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not change SSH login: $e'),
        backgroundColor: AppColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();
    final creds = _creds;
    final pw = creds?.password ?? '';
    const mono = TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace');

    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.key, color: AppColors.secondary, size: 20),
                SizedBox(width: 10),
                Text('SSH access',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            const SelectableText(
              'ssh ${SshDefaults.username}@localhost -p ${SshDefaults.port}',
              style: mono,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Password: ', style: TextStyle(color: Colors.white54, fontSize: 13)),
                Expanded(
                  child: Text(
                    creds == null ? '…' : (_reveal ? pw : '•' * 12),
                    style: mono,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: _reveal ? 'Hide password' : 'Show password',
                  icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility,
                      size: 18, color: Colors.white54),
                  onPressed: () => setState(() => _reveal = !_reveal),
                ),
                IconButton(
                  tooltip: 'Copy password',
                  icon: const Icon(Icons.copy, size: 18, color: Colors.white54),
                  onPressed: creds == null ? null : _copyPassword,
                ),
              ],
            ),
            const Text(
              'Generated for this install and kept in Android Keystore. '
              'Applied in the VM on every start.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const Divider(height: 24, color: Colors.white12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _keyOnlyPref,
              onChanged: _busy ? null : (v) => _setKeyOnly(v, vm),
              title: const Text('Key-only login',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                _keyOnlyPref
                    ? 'Password login is off from the next VM start. '
                        'The app logs in with its own key.'
                    : 'Turn off password login; the app uses its own key.',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
