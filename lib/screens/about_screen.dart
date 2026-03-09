import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: const [
          _CompanyBranding(),
          SizedBox(height: 24),
          _AppInfoCard(),
          SizedBox(height: 16),
          _LicenseCard(),
          SizedBox(height: 16),
          _DependenciesCard(),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Company branding ──────────────────────────────────────────────────────────

class _CompanyBranding extends StatelessWidget {
  const _CompanyBranding();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Image.asset(
          'assets/ai2th_logo.png',
          width: 260,
          filterQuality: FilterQuality.high,
        ),
        const SizedBox(height: 6),
        Text(
          'ai2th.github.io',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.35),
          ),
        ),
      ],
    );
  }
}

// ── App info ──────────────────────────────────────────────────────────────────

class _AppInfoCard extends StatelessWidget {
  const _AppInfoCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1D23),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // App icon
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                'assets/linxr_icon.png',
                width: 64,
                height: 64,
                filterQuality: FilterQuality.high,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Linxr',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D6EFD).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: const Color(0xFF0D6EFD).withOpacity(0.4),
                      ),
                    ),
                    child: const Text(
                      'v1.0.0',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF0D6EFD),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Bare Alpine Linux VM on Android — no root required. '
                    'Run a full Linux environment powered by QEMU.',
                    style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(Icons.business, 'Developer', 'AI2TH'),
                  const SizedBox(height: 4),
                  _InfoRow(Icons.memory, 'VM RAM', '1024 MB'),
                  const SizedBox(height: 4),
                  _InfoRow(Icons.terminal, 'SSH', 'root@localhost:2222  ·  pw: alpine'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.label, this.value);
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 13, color: Colors.white38),
        const SizedBox(width: 6),
        Text('$label: ', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ── License ───────────────────────────────────────────────────────────────────

class _LicenseCard extends StatelessWidget {
  const _LicenseCard();

  static const _mitText = '''MIT License

Copyright (c) 2026 AI2TH

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1D23),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.gavel, color: Color(0xFF20C997), size: 20),
          title: const Text('License',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          subtitle: const Text('MIT License — Open Source',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          iconColor: Colors.white38,
          collapsedIconColor: Colors.white38,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  _mitText,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Open-source dependencies ──────────────────────────────────────────────────

class _DependenciesCard extends StatelessWidget {
  const _DependenciesCard();

  static const _deps = [
    _Dep('Flutter', 'Google', 'BSD-3-Clause',
        'Cross-platform UI toolkit'),
    _Dep('dartssh2', 'Xclusive Dartssh2 Authors', 'MIT',
        'Pure-Dart SSH2 client & server'),
    _Dep('xterm', 'TerminalStudio', 'BSD-3-Clause',
        'Terminal emulator widget for Flutter'),
    _Dep('provider', 'Remi Rousselet', 'MIT',
        'State management wrapper for InheritedWidget'),
    _Dep('cupertino_icons', 'Flutter Team', 'MIT',
        'iOS-style icon assets'),
    _Dep('QEMU', 'QEMU Project', 'GPL-2.0',
        'Machine emulator and virtualiser'),
    _Dep('Alpine Linux', 'Alpine Linux Developers', 'MIT / GPL',
        'Security-oriented, lightweight Linux distribution'),
    _Dep('OpenSSH', 'OpenBSD Project', 'BSD',
        'Connectivity tools for remote login with SSH protocol'),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1A1D23),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.account_tree_outlined,
              color: Color(0xFF0D6EFD), size: 20),
          title: const Text('Open Source Components',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          subtitle: Text('${_deps.length} components',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
          iconColor: Colors.white38,
          collapsedIconColor: Colors.white38,
          children: [
            for (final d in _deps)
              _DepTile(dep: d),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Dep {
  const _Dep(this.name, this.author, this.license, this.desc);
  final String name;
  final String author;
  final String license;
  final String desc;
}

class _DepTile extends StatelessWidget {
  const _DepTile({required this.dep});
  final _Dep dep;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF20C997).withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: const Color(0xFF20C997).withOpacity(0.3)),
            ),
            child: Text(
              dep.license,
              style: const TextStyle(
                  fontSize: 9, color: Color(0xFF20C997), fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dep.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                Text(dep.author,
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                Text(dep.desc,
                    style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
