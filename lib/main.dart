import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/terminal_screen.dart';
import 'screens/about_screen.dart';
import 'services/vm_platform.dart';

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
          primary: const Color(0xFF0D6EFD),
          secondary: const Color(0xFF20C997),
          surface: const Color(0xFF1A1D23),
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0E1117),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF111827),
          indicatorColor: const Color(0xFF0D6EFD).withOpacity(0.2),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: Color(0xFF0D6EFD));
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
    AboutScreen(),
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
          NavigationDestination(icon: Icon(Icons.info_outline), label: 'About'),
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
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(),
            SizedBox(height: 16),
            _SshInfoCard(),
            SizedBox(height: 16),
            _ControlButton(),
          ],
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
      'running'  => ('Running', const Color(0xFF20C997), Icons.check_circle),
      'booting'  => ('Booting...', const Color(0xFFFFC107), Icons.hourglass_top),
      'starting' => ('Starting...', const Color(0xFFFFC107), Icons.hourglass_top),
      'error'    => ('Error', const Color(0xFFDC3545), Icons.error),
      _          => ('Stopped', Colors.white38, Icons.stop_circle_outlined),
    };

    return Card(
      color: const Color(0xFF1A1D23),
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
                            color: Color(0xFFDC3545), fontSize: 12)),
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
      color: const Color(0xFF1A1D23),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, color: Color(0xFF0D6EFD), size: 20),
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
                  color: isRunning ? const Color(0xFF20C997) : Colors.white38,
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
          backgroundColor: const Color(0xFFDC3545),
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
            backgroundColor: const Color(0xFF0D6EFD),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Boot + SSH ready takes 2–4 min',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}
