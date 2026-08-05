import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'screens/terminal_screen.dart';
import 'screens/containers_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/files_screen.dart';
import 'services/vm_platform.dart';
import 'theme.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => VmState(),
      child: const AlpineApp(),
    ),
  );
}

class AlpineApp extends StatelessWidget {
  const AlpineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linxr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: AppColors.primary,
          secondary: AppColors.secondary,
          surface: AppColors.surface,
        ),
        scaffoldBackgroundColor: AppColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: AppColors.navRail,
          indicatorColor: AppColors.primary.withOpacity(0.2),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: AppColors.primary);
            }
            return IconThemeData(color: Colors.white.withOpacity(0.4));
          }),
        ),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  static const _screens = <Widget>[
    _HomeScreen(),
    TerminalScreen(),
    ContainersScreen(),
    FilesScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VmState>().refreshStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.terminal), label: 'Terminal'),
          NavigationDestination(icon: Icon(Icons.widgets), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.folder_open), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Home screen
// ---------------------------------------------------------------------------

class _HomeScreen extends StatelessWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Linxr'), centerTitle: false),
      body: const SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(),
              SizedBox(height: 16),
              _SshInfoCard(),
              SizedBox(height: 16),
              _ControlButton(),
              SizedBox(height: 16),
              _SystemLogConsole(),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();

    final (label, color, icon) = switch (vm.status) {
      'running'  => ('Running', AppColors.secondary, Icons.check_circle),
      'booting'  => ('Booting...', AppColors.warning, Icons.hourglass_top),
      'starting' => ('Starting...', AppColors.warning, Icons.hourglass_top),
      'error'    => ('Error', AppColors.danger, Icons.error),
      _          => ('Stopped', Colors.white38, Icons.stop_circle_outlined),
    };

    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, color: color, size: 36),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Alpine Linux VM',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: Colors.white)),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                if (vm.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(vm.errorMessage!,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 12)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SshInfoCard extends StatelessWidget {
  const _SshInfoCard();

  @override
  Widget build(BuildContext context) {
    final isRunning = context.watch<VmState>().isRunning;

    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Text('Shell Access',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(color: Colors.white)),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Use the Terminal tab for a built-in shell.\n'
              'External SSH clients can also connect:',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'ssh root@localhost -p 2222  # password: alpine',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: isRunning ? AppColors.secondary : Colors.white38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();

    if (vm.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (vm.isBooting) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 10),
          const Text(
            'Booting — pinging SSH...',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      );
    }

    if (vm.isRunning) {
      return FilledButton.icon(
        onPressed: () => vm.stopVm(),
        icon: const Icon(Icons.stop),
        label: const Text('Stop VM'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.danger,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => vm.startVm(),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start VM'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Boot + SSH ready takes ~15–30 sec',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}

class _SystemLogConsole extends StatefulWidget {
  const _SystemLogConsole();

  @override
  State<_SystemLogConsole> createState() => _SystemLogConsoleState();
}

class _SystemLogConsoleState extends State<_SystemLogConsole> {
  bool _isExpanded = false;
  List<String> _logs = [];
  Timer? _timer;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _fetchLogs());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    final newLogs = await VmPlatform.getVmLogs();
    if (mounted && newLogs.length != _logs.length) {
      setState(() {
        _logs = newLogs;
      });
      if (_scrollController.hasClients && _isExpanded) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<VmState>();
    final isBooting = vm.isBooting;

    // Auto-expand logs while booting
    final showLogs = _isExpanded || isBooting;

    return Card(
      color: AppColors.surface,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.bug_report_outlined, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'System & VM Logs (${_logs.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
                    tooltip: 'Copy logs',
                    onPressed: _logs.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: _logs.join('\n')));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Logs copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white54),
                    tooltip: 'Clear logs',
                    onPressed: _logs.isEmpty
                        ? null
                        : () async {
                            await VmPlatform.clearVmLogs();
                            setState(() {
                              _logs.clear();
                            });
                          },
                  ),
                  Icon(
                    showLogs ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (showLogs)
            Container(
              height: 180,
              decoration: const BoxDecoration(
                color: Colors.black45,
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        'No logs recorded yet.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(10),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return SelectableText(
                          _logs[index],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.white70,
                            height: 1.3,
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
