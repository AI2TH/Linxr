import 'dart:async';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/vm_platform.dart';

// ─── Connection state ─────────────────────────────────────────────────────────

enum _ConnState { idle, connecting, connected }

// ─── Per-tab state ────────────────────────────────────────────────────────────

class _Tab {
  final String label;
  final Terminal terminal;
  final TerminalController controller;

  SSHClient? client;
  SSHSession? session;
  _ConnState connState = _ConnState.idle;
  Timer? retryTimer;
  int retryCount = 0;

  static const _maxRetries = 24; // ~2 minutes

  _Tab(this.label)
      : terminal = Terminal(maxLines: 5000),
        controller = TerminalController();

  void close() {
    retryTimer?.cancel();
    session?.stdin.close();
    client?.close();
    controller.dispose();
  }
}

// ─── Screen widget ────────────────────────────────────────────────────────────

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final List<_Tab> _tabs = [];
  int _activeIdx = 0;
  int _nextId = 1;

  static const _maxTabs = 5;

  _Tab get _active => _tabs[_activeIdx];

  @override
  void initState() {
    super.initState();
    _tabs.add(_Tab('Shell ${_nextId++}'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final status = context.read<VmState>().status;
      if (status == 'running') _scheduleConnect(_active, delaySeconds: 5);
    });
  }

  @override
  void dispose() {
    for (final t in _tabs) t.close();
    super.dispose();
  }

  // ── Tab management ──────────────────────────────────────────────────────────

  void _newTab() {
    if (_tabs.length >= _maxTabs) return;
    final tab = _Tab('Shell ${_nextId++}');
    _tabs.add(tab);
    setState(() => _activeIdx = _tabs.length - 1);
    // Connect immediately — this tab is now active
    final status = context.read<VmState>().status;
    if (status == 'running') _scheduleConnect(tab);
  }

  void _selectTab(int i) {
    setState(() => _activeIdx = i);
    final tab = _tabs[i];
    // Auto-connect if tab is idle and VM is running
    if (tab.connState == _ConnState.idle) {
      final status = context.read<VmState>().status;
      if (status == 'running') _scheduleConnect(tab);
    }
  }

  void _closeTab(int i) {
    if (_tabs.length == 1) return;
    _tabs[i].close();
    _tabs.removeAt(i);
    setState(() {
      if (_activeIdx >= _tabs.length) _activeIdx = _tabs.length - 1;
    });
  }

  // ── SSH connection ──────────────────────────────────────────────────────────

  void _scheduleConnect(_Tab tab, {int delaySeconds = 0}) {
    tab.retryTimer?.cancel();
    tab.retryTimer =
        Timer(Duration(seconds: delaySeconds), () => _connect(tab));
  }

  Future<void> _connect(_Tab tab) async {
    if (tab.connState == _ConnState.connecting ||
        tab.connState == _ConnState.connected) return;

    setState(() => tab.connState = _ConnState.connecting);
    tab.terminal.write('\r\nConnecting to Linxr...\r\n');

    try {
      final socket = await SSHSocket.connect('127.0.0.1', 2222)
          .timeout(const Duration(seconds: 10));

      tab.client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 'alpine',
      );

      tab.session = await tab.client!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: tab.terminal.viewWidth,
          height: tab.terminal.viewHeight,
        ),
      );

      tab.session!.stdout.listen(
        (data) => tab.terminal.write(String.fromCharCodes(data)),
        onDone: () => _onSessionDone(tab),
      );
      tab.session!.stderr.listen(
        (data) => tab.terminal.write(String.fromCharCodes(data)),
      );

      tab.terminal.onOutput = (data) {
        tab.session?.stdin.add(Uint8List.fromList(data.codeUnits));
      };
      tab.terminal.onResize = (w, h, pw, ph) {
        tab.session?.resizeTerminal(w, h);
      };

      tab.retryCount = 0;
      if (mounted) setState(() => tab.connState = _ConnState.connected);
    } on TimeoutException {
      _retryOrError(tab,
          'Timed out (${tab.retryCount + 1}/${_Tab._maxRetries})');
    } catch (e) {
      _retryOrError(tab, 'Failed: $e');
    }
  }

  void _retryOrError(_Tab tab, String msg) {
    if (!mounted) return;
    tab.retryCount++;
    final isActive = _tabs.indexOf(tab) == _activeIdx;
    if (tab.retryCount < _Tab._maxRetries) {
      setState(() => tab.connState = _ConnState.idle);
      if (isActive) {
        // Only active tab retries automatically — background tabs wait until selected
        tab.terminal.write('\r\n[$msg — retrying in 5s...]\r\n');
        _scheduleConnect(tab, delaySeconds: 5);
      } else {
        tab.terminal.write('\r\n[$msg — will retry when tab is selected]\r\n');
      }
    } else {
      tab.retryCount = 0;
      setState(() => tab.connState = _ConnState.idle);
      tab.terminal.write('\r\nERROR: $msg — gave up.\r\n');
    }
  }

  void _onSessionDone(_Tab tab) {
    if (mounted) {
      tab.terminal.write('\r\n\r\n[Session closed]\r\n');
      setState(() => tab.connState = _ConnState.idle);
    }
  }

  void _reconnect() {
    final tab = _active;
    tab.retryTimer?.cancel();
    tab.retryCount = 0;
    tab.session?.stdin.close();
    tab.client?.close();
    tab.session = null;
    tab.client = null;
    tab.terminal.write('\r\n--- Reconnecting ---\r\n');
    _connect(tab);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final vmStatus = context.watch<VmState>().status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          _StatusChip(_active.connState),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reconnect',
            onPressed: vmStatus == 'running' ? _reconnect : null,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _TabBar(
            tabs: _tabs,
            activeIndex: _activeIdx,
            canAdd: _tabs.length < _maxTabs,
            onSelect: _selectTab,
            onClose: _tabs.length > 1 ? _closeTab : null,
            onAdd: _newTab,
          ),
          if (vmStatus != 'running')
            _Banner(
              icon: Icons.warning_amber,
              color: const Color(0xFFFFC107),
              message: 'VM is not running. Start it from the Home tab.',
            )
          else if (_active.connState == _ConnState.idle)
            _Banner(
              icon: Icons.info_outline,
              color: const Color(0xFF0D6EFD),
              message: 'Not connected.',
              action: TextButton(
                onPressed: () => _connect(_active),
                child: const Text('Connect',
                    style: TextStyle(color: Colors.white)),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _activeIdx,
              children: [
                for (final tab in _tabs)
                  TerminalView(
                    tab.terminal,
                    controller: tab.controller,
                    autofocus: true,
                    backgroundOpacity: 1,
                    theme: _kTermTheme,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tab bar ──────────────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.activeIndex,
    required this.canAdd,
    required this.onSelect,
    required this.onClose,
    required this.onAdd,
  });

  final List<_Tab> tabs;
  final int activeIndex;
  final bool canAdd;
  final ValueChanged<int> onSelect;
  final ValueChanged<int>? onClose;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      color: const Color(0xFF111827),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (_, i) {
                final active = i == activeIndex;
                final tab = tabs[i];
                final dotColor = switch (tab.connState) {
                  _ConnState.connected  => const Color(0xFF20C997),
                  _ConnState.connecting => const Color(0xFFFFC107),
                  _ConnState.idle       => Colors.white24,
                };
                return GestureDetector(
                  onTap: () => onSelect(i),
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 80, maxWidth: 130),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF0E1117)
                          : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: active
                              ? const Color(0xFF0D6EFD)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                              shape: BoxShape.circle, color: dotColor),
                        ),
                        Flexible(
                          child: Text(
                            tab.label,
                            style: TextStyle(
                              fontSize: 12,
                              color: active ? Colors.white : Colors.white54,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (onClose != null)
                          GestureDetector(
                            onTap: () => onClose!(i),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.close,
                                size: 13,
                                color: active
                                    ? Colors.white60
                                    : Colors.white24,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (canAdd)
            InkWell(
              onTap: onAdd,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(Icons.add, size: 16, color: Colors.white54),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Shared widgets ───────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.state);
  final _ConnState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      _ConnState.connected  => ('Connected', const Color(0xFF20C997)),
      _ConnState.connecting => ('Connecting...', const Color(0xFFFFC107)),
      _ConnState.idle       => ('Disconnected', Colors.white38),
    };
    return Chip(
      label: Text(label, style: TextStyle(color: color, fontSize: 11)),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: color.withOpacity(0.4)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(
      {required this.icon,
      required this.color,
      required this.message,
      this.action});
  final IconData icon;
  final Color color;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color.withOpacity(0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style: TextStyle(color: color, fontSize: 13))),
          if (action != null) action!,
        ],
      ),
    );
  }
}

// ─── Terminal theme (shared across all tabs) ──────────────────────────────────

const _kTermTheme = TerminalTheme(
  cursor: Color(0xFF20C997),
  selection: Color(0x440D6EFD),
  foreground: Color(0xFFE0E0E0),
  background: Color(0xFF0E1117),
  black: Color(0xFF1A1D23),
  white: Color(0xFFE0E0E0),
  red: Color(0xFFDC3545),
  green: Color(0xFF20C997),
  yellow: Color(0xFFFFC107),
  blue: Color(0xFF0D6EFD),
  magenta: Color(0xFF9B59B6),
  cyan: Color(0xFF17A2B8),
  brightBlack: Color(0xFF6C757D),
  brightWhite: Color(0xFFFFFFFF),
  brightRed: Color(0xFFFF6B6B),
  brightGreen: Color(0xFF5EF0B0),
  brightYellow: Color(0xFFFFD93D),
  brightBlue: Color(0xFF74B9FF),
  brightMagenta: Color(0xFFBB8FCE),
  brightCyan: Color(0xFF48C9B0),
  searchHitBackground: Color(0x44FFFFFF),
  searchHitBackgroundCurrent: Color(0x660D6EFD),
  searchHitForeground: Color(0xFF000000),
);
