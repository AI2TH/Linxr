import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/vm_platform.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Keys must match what VmManager.kt reads from FlutterSharedPreferences
  static const _kVcpu = 'flutter.vcpu_count';
  static const _kRam  = 'flutter.ram_mb';
  static const _kDisk = 'flutter.disk_gb';

  DeviceInfo? _device;
  int? _vcpu;   // null = auto
  int? _ramMb;  // null = auto
  int? _diskGb; // null = auto
  bool _loaded = false;

  // ── Derived ranges from device info ────────────────────────────────────────

  int get _maxVcpu => _device?.cores ?? 4;

  // Total RAM rounded down to nearest 512 MB step, min 512
  int get _maxRamMb {
    final total = _device?.totalRamMb ?? 4096;
    return max(512, (total ~/ 512) * 512);
  }

  // Free storage minus 2 GB headroom, rounded to nearest 8 GB step, min 8
  int get _maxDiskGb {
    final free = _device?.freeStorageGb ?? 32;
    final usable = max(8, free - 2);
    return (usable ~/ 8) * 8;
  }

  // Auto defaults — mirrors VmManager.kt logic
  int get _autoVcpu => max(1, (_device?.cores ?? 4) ~/ 2);
  int get _autoRamMb {
    final total = _device?.totalRamMb ?? 4096;
    return max(512, total ~/ 4);
  }
  int get _autoDiskGb => max(8, (_device?.freeStorageGb ?? 32) - 2);

  // Effective displayed values (user setting or auto default)
  int get _effectiveVcpu   => _vcpu   ?? _autoVcpu;
  int get _effectiveRamMb  => _ramMb  ?? _autoRamMb;
  int get _effectiveDiskGb => _diskGb ?? _autoDiskGb;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      VmPlatform.getDeviceInfo(),
      SharedPreferences.getInstance(),
    ]);
    final device = results[0] as DeviceInfo;
    final prefs  = results[1] as SharedPreferences;
    setState(() {
      _device = device;
      final v = prefs.getInt(_kVcpu);
      final r = prefs.getInt(_kRam);
      final d = prefs.getInt(_kDisk);
      _vcpu   = (v != null && v > 0) ? v : null;
      _ramMb  = (r != null && r > 0) ? r : null;
      _diskGb = (d != null && d > 0) ? d : null;
      _loaded = true;
    });
  }

  // ── Persist ─────────────────────────────────────────────────────────────────

  Future<void> _saveVcpu(int? value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _vcpu = value);
    if (value == null) await prefs.remove(_kVcpu);
    else await prefs.setInt(_kVcpu, value);
  }

  Future<void> _saveRam(int? value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _ramMb = value);
    if (value == null) await prefs.remove(_kRam);
    else await prefs.setInt(_kRam, value);
  }

  Future<void> _saveDisk(int? value) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _diskGb = value);
    if (value == null) await prefs.remove(_kDisk);
    else await prefs.setInt(_kDisk, value);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader('VM Resources'),
                const SizedBox(height: 8),

                // ── vCPU ──────────────────────────────────────────────────────
                _SettingCard(
                  icon: Icons.developer_board,
                  iconColor: const Color(0xFF0D6EFD),
                  title: 'vCPU Cores',
                  isAuto: _vcpu == null,
                  valueLabel: _vcpu == null
                      ? 'Auto — $_autoVcpu of $_maxVcpu cores'
                      : '$_effectiveVcpu of $_maxVcpu cores',
                  onClearAuto: () => _saveVcpu(null),
                  child: _IntSlider(
                    value: _effectiveVcpu.clamp(1, _maxVcpu),
                    min: 1,
                    max: _maxVcpu,
                    onChanged: (v) => _saveVcpu(v),
                    labelSuffix: 'core',
                    labelSuffixPlural: 'cores',
                  ),
                ),
                const SizedBox(height: 12),

                // ── RAM ───────────────────────────────────────────────────────
                _SettingCard(
                  icon: Icons.memory,
                  iconColor: const Color(0xFF20C997),
                  title: 'RAM',
                  isAuto: _ramMb == null,
                  valueLabel: _ramMb == null
                      ? 'Auto — ${_fmtMb(_autoRamMb)} of ${_fmtMb(_maxRamMb)}'
                      : '${_fmtMb(_effectiveRamMb)} of ${_fmtMb(_maxRamMb)}',
                  onClearAuto: () => _saveRam(null),
                  child: _StepSlider(
                    value: _effectiveRamMb.clamp(512, _maxRamMb),
                    min: 512,
                    max: _maxRamMb,
                    step: 512,
                    onChanged: (v) => _saveRam(v),
                    labelFn: _fmtMb,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Disk ──────────────────────────────────────────────────────
                _SettingCard(
                  icon: Icons.storage,
                  iconColor: const Color(0xFFFFC107),
                  title: 'Disk Cap',
                  isAuto: _diskGb == null,
                  valueLabel: _diskGb == null
                      ? 'Auto — ${_autoDiskGb} GB of ${_maxDiskGb} GB free'
                      : '${_effectiveDiskGb} GB virtual disk',
                  onClearAuto: () => _saveDisk(null),
                  note: 'Disk changes take effect only after a VM data reset.',
                  child: _StepSlider(
                    value: _effectiveDiskGb.clamp(8, _maxDiskGb),
                    min: 8,
                    max: _maxDiskGb,
                    step: 8,
                    onChanged: (v) => _saveDisk(v),
                    labelFn: (v) => '$v GB',
                  ),
                ),

                const SizedBox(height: 24),
                _SectionHeader('When changes apply'),
                const SizedBox(height: 8),
                Card(
                  color: const Color(0xFF1A1D23),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        _ChangeRow(Icons.play_arrow, 'vCPU & RAM',
                            'Next VM start'),
                        SizedBox(height: 8),
                        _ChangeRow(Icons.warning_amber_rounded, 'Disk Cap',
                            'VM data reset (clears all installed packages)'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  static String _fmtMb(int mb) {
    if (mb < 1024) return '${mb}MB';
    if (mb % 1024 == 0) return '${mb ~/ 1024}GB';
    return '${(mb / 1024).toStringAsFixed(1)}GB';
  }
}

// ---------------------------------------------------------------------------
// Slider widgets
// ---------------------------------------------------------------------------

class _IntSlider extends StatelessWidget {
  const _IntSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.labelSuffix,
    required this.labelSuffixPlural,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String labelSuffix;
  final String labelSuffixPlural;

  @override
  Widget build(BuildContext context) {
    final divisions = max - min;
    return Column(
      children: [
        Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: divisions > 0 ? divisions : 1,
          label: '$value ${value == 1 ? labelSuffix : labelSuffixPlural}',
          onChanged: (v) => onChanged(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _tickLabel('$min'),
              _tickLabel('$max'),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepSlider extends StatelessWidget {
  const _StepSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.labelFn,
  });

  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;
  final String Function(int) labelFn;

  @override
  Widget build(BuildContext context) {
    final steps = (max - min) ~/ step;
    final sliderVal = ((value - min) / step).roundToDouble().clamp(0.0, steps.toDouble());
    return Column(
      children: [
        Slider(
          value: sliderVal,
          min: 0,
          max: steps.toDouble(),
          divisions: steps > 0 ? steps : 1,
          label: labelFn(min + sliderVal.round() * step),
          onChanged: (v) => onChanged(min + v.round() * step),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _tickLabel(labelFn(min)),
              _tickLabel(labelFn(min + (steps ~/ 2) * step)),
              _tickLabel(labelFn(max)),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _tickLabel(String text) => Text(
      text,
      style: const TextStyle(color: Colors.white24, fontSize: 10),
    );

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
        ),
      );
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.isAuto,
    required this.valueLabel,
    required this.onClearAuto,
    required this.child,
    this.note,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final bool isAuto;
  final String valueLabel;
  final VoidCallback onClearAuto;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1D23),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                ),
                if (!isAuto)
                  TextButton(
                    onPressed: onClearAuto,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Auto',
                        style: TextStyle(
                            color: Color(0xFF0D6EFD), fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              valueLabel,
              style: TextStyle(
                color: isAuto ? const Color(0xFF20C997) : Colors.white54,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            child,
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Text(note!,
                    style: const TextStyle(
                        color: Color(0xFFFFC107), fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow(this.icon, this.label, this.desc);
  final IconData icon;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: Colors.white38),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 12, height: 1.4),
              children: [
                TextSpan(
                    text: '$label  ',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600)),
                TextSpan(
                    text: desc,
                    style: const TextStyle(color: Colors.white38)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
