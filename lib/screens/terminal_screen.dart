import 'dart:async';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../services/vm_platform.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _terminal = Terminal(maxLines: 5000);
  final _terminalController = TerminalController();

  SSHClient? _client;
  SSHSession? _session;

  _ConnState _connState = _ConnState.idle;
  String? _error;
  Timer? _retryTimer;
  int _retryCount = 0;
  static const _maxRetries = 24; // 2 minutes total

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final status = context.read<VmState>().status;
      if (status == 'running') _scheduleConnect(delaySeconds: 5);
    });
  }

  void _scheduleConnect({int delaySeconds = 0}) {
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: delaySeconds), _connect);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _disconnect();
    _terminalController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connState == _ConnState.connecting || _connState == _ConnState.connected) return;

    setState(() {
      _connState = _ConnState.connecting;
      _error = null;
    });
    _terminal.write('\r\nConnecting to Linxr...\r\n');

    try {
      final socket = await SSHSocket.connect('127.0.0.1', 2222)
          .timeout(const Duration(seconds: 10));

      _client = SSHClient(
        socket,
        username: 'root',
        onPasswordRequest: () => 'alpine',
      );

      _session = await _client!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      // VM output → terminal display
      _session!.stdout.listen(
        (data) => _terminal.write(String.fromCharCodes(data)),
        onDone: _onSessionDone,
      );
      _session!.stderr.listen(
        (data) => _terminal.write(String.fromCharCodes(data)),
      );

      // Keyboard input → SSH session
      _terminal.onOutput = (data) {
        _session?.stdin.add(Uint8List.fromList(data.codeUnits));
      };

      // Terminal resize → SSH PTY resize
      _terminal.onResize = (w, h, pw, ph) {
        _session?.resizeTerminal(w, h);
      };

      _retryCount = 0;
      if (mounted) setState(() => _connState = _ConnState.connected);
    } on TimeoutException {
      _retryOrError('Connection timed out (attempt ${_retryCount + 1}/$_maxRetries)');
    } catch (e) {
      _retryOrError('Connection failed: $e');
    }
  }

  void _retryOrError(String msg) {
    if (!mounted) return;
    _retryCount++;
    if (_retryCount < _maxRetries) {
      setState(() { _connState = _ConnState.idle; });
      _terminal.write('\r\n[$msg — retrying in 5s...]\r\n');
      _scheduleConnect(delaySeconds: 5);
    } else {
      _retryCount = 0;
      _setError('$msg — gave up after $_maxRetries attempts.');
    }
  }

  void _onSessionDone() {
    if (mounted) {
      _terminal.write('\r\n\r\n[Session closed]\r\n');
      setState(() => _connState = _ConnState.idle);
    }
  }

  void _setError(String msg) {
    if (mounted) {
      setState(() {
        _connState = _ConnState.idle;
        _error = msg;
      });
      _terminal.write('\r\nERROR: $msg\r\n');
    }
  }

  void _disconnect() {
    _session?.stdin.close();
    _client?.close();
    _session = null;
    _client = null;
  }

  void _reconnect() {
    _retryTimer?.cancel();
    _retryCount = 0;
    _disconnect();
    _terminal.write('\r\n--- Reconnecting ---\r\n');
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    final vmStatus = context.watch<VmState>().status;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          _StatusChip(_connState),
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
          if (vmStatus != 'running')
            _Banner(
              icon: Icons.warning_amber,
              color: const Color(0xFFFFC107),
              message: 'VM is not running. Start it from the Home tab.',
            )
          else if (_connState == _ConnState.idle)
            _Banner(
              icon: Icons.info_outline,
              color: const Color(0xFF0D6EFD),
              message: 'Not connected.',
              action: TextButton(
                onPressed: _connect,
                child: const Text('Connect', style: TextStyle(color: Colors.white)),
              ),
            ),
          Expanded(
            child: TerminalView(
              _terminal,
              controller: _terminalController,
              autofocus: true,
              backgroundOpacity: 1,
              theme: const TerminalTheme(
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ConnState { idle, connecting, connected }

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
  const _Banner({required this.icon, required this.color, required this.message, this.action});
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
          Expanded(child: Text(message, style: TextStyle(color: color, fontSize: 13))),
          if (action != null) action!,
        ],
      ),
    );
  }
}
