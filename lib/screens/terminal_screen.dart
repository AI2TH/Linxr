import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/vm_platform.dart';
import '../theme.dart';
import '../constants.dart';

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
  Timer? keepAliveTimer;
  int retryCount = 0;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;

  static const _maxRetries = 24; // ~2 minutes

  _Tab(this.label)
      : terminal = Terminal(maxLines: 5000),
        controller = TerminalController();

  void startKeepAlive(VoidCallback onDead) {
    keepAliveTimer?.cancel();
    keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (connState != _ConnState.connected) return;
      try {
        // Send CR byte to probe liveness — non-empty payload avoids SSH-layer coalescing
        session?.stdin.add(Uint8List.fromList([13]));  // 13 = CR
      } catch (_) {
        onDead();
      }
    });
  }

  void stopKeepAlive() {
    keepAliveTimer?.cancel();
    keepAliveTimer = null;
  }

  void close() {
    retryTimer?.cancel();
    keepAliveTimer?.cancel();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
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

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  final List<_Tab> _tabs = [];
  int _activeIdx = 0;
  int _nextId = 1;
  String _lastVmStatus = '';

  static const _maxTabs = 5;

  _Tab get _active => _tabs[_activeIdx];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabs.add(_Tab('Shell ${_nextId++}'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final vmState = context.read<VmState>();
      _lastVmStatus = vmState.status;
      vmState.addListener(_onVmStateChanged);
      if (vmState.status == 'running') _scheduleConnect(_active, delaySeconds: 5);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try { context.read<VmState>().removeListener(_onVmStateChanged); } catch (_) {}
    for (final t in _tabs) t.close();
    super.dispose();
  }

  // ── App lifecycle: reconnect when returning to foreground ───────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final vmStatus = context.read<VmState>().status;
    if (vmStatus != 'running') return;
    for (final tab in _tabs) {
      if (tab.connState == _ConnState.idle) {
        tab.retryCount = 0;
        _scheduleConnect(tab, delaySeconds: 1);
      }
    }
    if (mounted) setState(() {});
  }

  // ── VM status listener ──────────────────────────────────────────────────────

  void _onVmStateChanged() {
    final status = context.read<VmState>().status;
    if (_lastVmStatus == 'running' && status != 'running') {
      _disconnectAll();
    } else if (_lastVmStatus != 'running' && status == 'running') {
      // VM just became ready — connect the active tab
      if (_active.connState == _ConnState.idle) {
        _scheduleConnect(_active, delaySeconds: 3);
      }
    }
    _lastVmStatus = status;
  }

  void _disconnectAll() {
    for (final tab in _tabs) {
      tab.retryTimer?.cancel();
      tab.stopKeepAlive();
      tab.session?.stdin.close();
      tab.client?.close();
      tab.session = null;
      tab.client = null;
      if (tab.connState != _ConnState.idle) {
        tab.terminal.write('\r\n[VM stopped — session closed]\r\n');
      }
      tab.connState = _ConnState.idle;
      tab.retryCount = 0;
    }
    if (mounted) setState(() {});
  }

  // ── Clipboard ───────────────────────────────────────────────────────────────

  Future<void> _paste() async {
    if (_active.connState != _ConnState.connected) return;
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _active.session?.stdin.add(Uint8List.fromList(utf8.encode(text)));
  }

  void _sendKey(List<int> bytes) {
    if (_active.connState != _ConnState.connected) return;
    _active.session?.stdin.add(Uint8List.fromList(bytes));
  }

  Future<void> _copySelection() async {
    final selection = _active.controller.selection;
    if (selection == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Long-press and drag to select text first'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }
    final text = _active.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Copied'),
        duration: Duration(seconds: 1),
      ));
    }
  }

  void _showClipboardMenu(TapDownDetails details, CellOffset offset) {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: AppColors.surface,
      items: [
        const PopupMenuItem(value: 'paste', child: Row(children: [
          Icon(Icons.content_paste, size: 16, color: Colors.white70),
          SizedBox(width: 10),
          Text('Paste', style: TextStyle(color: Colors.white70)),
        ])),
        const PopupMenuItem(value: 'copy', child: Row(children: [
          Icon(Icons.content_copy, size: 16, color: Colors.white70),
          SizedBox(width: 10),
          Text('Copy selection', style: TextStyle(color: Colors.white70)),
        ])),
      ],
    ).then((v) {
      if (v == 'paste') _paste();
      if (v == 'copy') _copySelection();
    });
  }

  // ── Tab management ──────────────────────────────────────────────────────────

  void _newTab() {
    if (_tabs.length >= _maxTabs) return;
    final tab = _Tab('Shell ${_nextId++}');
    _tabs.add(tab);
    setState(() => _activeIdx = _tabs.length - 1);
    final status = context.read<VmState>().status;
    if (status == 'running') _scheduleConnect(tab);
  }

  void _selectTab(int i) {
    setState(() => _activeIdx = i);
    final tab = _tabs[i];
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
      final socket = await SSHSocket.connect(SshDefaults.host, SshDefaults.port)
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      tab.client = SSHClient(
        socket,
        username: SshDefaults.username,
        onPasswordRequest: () => SshDefaults.password,
      );

      tab.session = await tab.client!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: tab.terminal.viewWidth,
          height: tab.terminal.viewHeight,
        ),
      );
      if (!mounted) return;

      tab._stdoutSub = tab.session!.stdout.listen(
        (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
        onDone: () => _onSessionDone(tab),
      );
      tab._stderrSub = tab.session!.stderr.listen(
        (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
      );

      tab.terminal.onOutput = (data) {
        tab.session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
      };
      tab.terminal.onResize = (w, h, pw, ph) {
        tab.session?.resizeTerminal(w, h);
      };

      tab.retryCount = 0;
      tab.startKeepAlive(() => _onSessionDone(tab));
      if (mounted) setState(() => tab.connState = _ConnState.connected);
    } on TimeoutException {
      _retryOrError(tab, 'Timed out (${tab.retryCount + 1}/${_Tab._maxRetries})');
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
    tab.stopKeepAlive();
    tab._stdoutSub?.cancel();
    tab._stderrSub?.cancel();
    tab.session = null;
    tab.client = null;
    if (!mounted) return;
    tab.terminal.write('\r\n\r\n[Session closed]\r\n');
    setState(() => tab.connState = _ConnState.idle);
    // Auto-reconnect if VM is still running
    final vmStatus = context.read<VmState>().status;
    if (vmStatus == 'running' && tab.retryCount < _Tab._maxRetries) {
      _scheduleConnect(tab, delaySeconds: 5);
    }
  }

  void _reconnect() {
    final tab = _active;
    tab.retryTimer?.cancel();
    tab.stopKeepAlive();
    tab.retryCount = 0;
    tab.session?.stdin.close();
    tab.client?.close();
    tab.session = null;
    tab.client = null;
    tab.connState = _ConnState.idle;
    tab.terminal.write('\r\n--- Reconnecting ---\r\n');
    _connect(tab);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final vmStatus = context.watch<VmState>().status;
    final connected = _active.connState == _ConnState.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          _StatusChip(_active.connState),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.content_copy, size: 20),
            tooltip: 'Copy selection',
            onPressed: connected ? _copySelection : null,
          ),
          IconButton(
            icon: const Icon(Icons.content_paste, size: 20),
            tooltip: 'Paste',
            onPressed: connected ? _paste : null,
          ),
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
              color: AppColors.warning,
              message: 'VM is not running. Start it from the Home tab.',
            )
          else if (_active.connState == _ConnState.idle)
            _Banner(
              icon: Icons.info_outline,
              color: AppColors.primary,
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
                    onSecondaryTapDown: _showClipboardMenu,
                  ),
              ],
            ),
          ),
          _KeyRow(onKey: _sendKey, enabled: _active.connState == _ConnState.connected),
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
      color: AppColors.navRail,
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
                  _ConnState.connected  => AppColors.secondary,
                  _ConnState.connecting => AppColors.warning,
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
                          ? AppColors.background
                          : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: active
                              ? AppColors.primary
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
      _ConnState.connected  => ('Connected', AppColors.secondary),
      _ConnState.connecting => ('Connecting...', AppColors.warning),
      _ConnState.idle       => ('Disconnected', Colors.white38),
    };
    return Chip(
      label: Text(label, style: TextStyle(color: color, fontSize: 11)),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: color.withValues(alpha: 0.4)),
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
      color: color.withValues(alpha: 0.12),
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

// ─── Extra key row (Tab, arrows, Ctrl sequences) ──────────────────────────────

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.onKey, required this.enabled});
  final void Function(List<int> bytes) onKey;
  final bool enabled;

  static const _keys = <(String, List<int>)>[
    ('Tab',  [0x09]),           // Tab — triggers shell autocomplete
    ('Esc',  [0x1b]),           // Escape
    ('↑',    [0x1b, 0x5b, 0x41]), // Arrow up — history prev
    ('↓',    [0x1b, 0x5b, 0x42]), // Arrow down — history next
    ('←',    [0x1b, 0x5b, 0x44]), // Arrow left
    ('→',    [0x1b, 0x5b, 0x43]), // Arrow right
    ('C-c',  [0x03]),           // Ctrl+C — interrupt
    ('C-d',  [0x04]),           // Ctrl+D — EOF / logout
    ('C-z',  [0x1a]),           // Ctrl+Z — suspend
    ('C-l',  [0x0c]),           // Ctrl+L — clear screen
    ('Home', [0x1b, 0x5b, 0x48]),
    ('End',  [0x1b, 0x5b, 0x46]),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: AppColors.navRail,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        itemCount: _keys.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final (label, bytes) = _keys[i];
          final isTab = label == 'Tab';
          return GestureDetector(
            onTap: enabled ? () => onKey(bytes) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isTab
                    ? AppColors.primary.withValues(alpha: enabled ? 0.25 : 0.08)
                    : Colors.white.withValues(alpha: enabled ? 0.07 : 0.03),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: isTab
                      ? AppColors.primary.withValues(alpha: enabled ? 0.5 : 0.15)
                      : Colors.white.withValues(alpha: enabled ? 0.12 : 0.05),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: isTab ? FontWeight.bold : FontWeight.normal,
                  color: enabled
                      ? (isTab ? AppColors.brightBlue : Colors.white70)
                      : Colors.white24,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Terminal theme ───────────────────────────────────────────────────────────

const _kTermTheme = TerminalTheme(
  cursor: AppColors.xtermCursor,
  selection: Color(0x440D6EFD),
  foreground: AppColors.xtermWhite,
  background: AppColors.xtermBackground,
  black: AppColors.xtermBlack,
  white: AppColors.xtermWhite,
  red: AppColors.termRed,
  green: AppColors.termGreen,
  yellow: AppColors.termYellow,
  blue: AppColors.termBlue,
  magenta: AppColors.termMagenta,
  cyan: AppColors.termCyan,
  brightBlack: AppColors.brightBlack,
  brightWhite: AppColors.brightWhite,
  brightRed: AppColors.brightRed,
  brightGreen: AppColors.brightGreen,
  brightYellow: AppColors.brightYellow,
  brightBlue: AppColors.brightBlue,
  brightMagenta: AppColors.brightMagenta,
  brightCyan: AppColors.brightCyan,
  searchHitBackground: Color(0x44FFFFFF),
  searchHitBackgroundCurrent: Color(0x660D6EFD),
  searchHitForeground: AppColors.xtermSearchHitFg,
);
