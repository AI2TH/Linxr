import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/marketplace_item.dart';
import 'vm_platform.dart';

class MarketplaceService {
  static const String _kCustomRecipesKey = 'custom_marketplace_recipes';

  static final List<MarketplaceItem> builtInItems = [
    // ── Desktop & GUI Environments ──────────────────────────────────────────
    const MarketplaceItem(
      id: 'desktop-openbox',
      name: 'Virtual Desktop — Openbox (Native)',
      category: 'Desktop & GUI',
      type: RecipeType.script,
      author: 'Linxr Desktop / Alpine',
      version: '1.0',
      iconCodePoint: 0xe1cb, // Icons.desktop_windows
      description:
          'Ultra-lightweight Linux GUI desktop with Openbox window manager, tint2 taskbar panel, PCManFM file manager, Mousepad text editor, and XTerm. Low RAM footprint (<25 MB), mobile-optimized noVNC touch controls.',
      script:
          '/usr/local/bin/linxr-desktop install openbox && /usr/local/bin/linxr-desktop start 1280x720 openbox',
      ports: [
        {'host': 6080, 'container': 6080},
        {'host': 5900, 'container': 5900},
      ],
      notes:
          'Open http://localhost:6080 in mobile browser or use the Virtual Desktop screen inside Linxr. Standard VNC viewer connects to port 5900.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'desktop-xfce',
      name: 'Virtual Desktop — XFCE4 (Native)',
      category: 'Desktop & GUI',
      type: RecipeType.script,
      author: 'Linxr Desktop / XFCE',
      version: '4.18',
      iconCodePoint: 0xe1cb, // Icons.desktop_windows
      description:
          'Complete XFCE4 desktop suite with Thunar file manager, Mousepad, XFCE Terminal, window manager, and settings. Smooth WebGL hardware-accelerated noVNC rendering.',
      script:
          '/usr/local/bin/linxr-desktop install xfce4 && /usr/local/bin/linxr-desktop start 1280x720 xfce4',
      ports: [
        {'host': 6080, 'container': 6080},
        {'host': 5900, 'container': 5900},
      ],
      notes:
          'Open http://localhost:6080 in your phone browser or use the Linxr Virtual Desktop screen. Connect any VNC app to port 5900.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'desktop-webtop-docker',
      name: 'Virtual Desktop — Webtop (Docker)',
      category: 'Desktop & GUI',
      type: RecipeType.docker,
      author: 'LinuxServer.io',
      version: 'alpine-xfce',
      iconCodePoint: 0xe1cb, // Icons.desktop_windows
      image: 'lscr.io/linuxserver/webtop:alpine-xfce',
      ports: [
        {'host': 3000, 'container': 3000},
      ],
      description:
          'Isolated containerized Linux XFCE desktop environment by LinuxServer.io. Includes web browser, audio support, and touch-screen clipboard sync.',
      notes:
          'Web desktop UI is served at http://localhost:3000. Open in Chrome on your phone to interact with the containerized desktop.',
      isCustom: false,
    ),

    // ── Kubernetes & DevOps ──────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'k3s',
      name: 'k3s Kubernetes',
      category: 'Kubernetes & DevOps',
      type: RecipeType.script,
      author: 'Rancher / CNCF',
      version: 'v1.30.0',
      iconCodePoint: 0xe17f, // Icons.cloud_circle
      description:
          'Lightweight certified Kubernetes (k3s) optimized for ARM64. Installs a fully functional single-node control-plane and worker.',
      script:
          'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -',
      notes:
          'Once installation completes, switch to the Terminal tab and run "kubectl get nodes" or "kubectl get pods -A" to monitor your cluster. Kubeconfig is saved at /etc/rancher/k3s/k3s.yaml.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'portainer',
      name: 'Portainer CE',
      category: 'Kubernetes & DevOps',
      type: RecipeType.docker,
      author: 'Portainer.io',
      version: 'latest',
      iconCodePoint: 0xe1bd, // Icons.dashboard
      image: 'portainer/portainer-ce:latest',
      ports: [
        {'host': 9000, 'container': 9000}
      ],
      description:
          'Powerful web-based management UI for Docker containers, images, volumes, and networks.',
      notes:
          'After deployment, open http://localhost:9000 in your browser to create your admin account and manage containers visually.',
      isCustom: false,
    ),

    // ── Dev Environments ────────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'vscode',
      name: 'VS Code Server',
      category: 'Dev Environments',
      type: RecipeType.docker,
      author: 'Coder',
      version: 'latest',
      iconCodePoint: 0xe16b, // Icons.code
      image: 'codercom/code-server:latest',
      ports: [
        {'host': 8443, 'container': 8443}
      ],
      env: [
        {'key': 'PASSWORD', 'value': 'linxr'}
      ],
      description:
          'Full Visual Studio Code IDE running inside your browser with extensions, integrated terminal, and file explorer.',
      notes:
          'Access your IDE at http://localhost:8443 in your browser. Default password is "linxr".',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'nodejs',
      name: 'Node.js 20 LTS',
      category: 'Dev Environments',
      type: RecipeType.docker,
      author: 'Node.js Foundation',
      version: '20-alpine',
      iconCodePoint: 0xe35b, // Icons.javascript
      image: 'node:20-alpine',
      command: [
        'sh',
        '-c',
        'node -e "console.log(\'Node.js Ready\'); setInterval(()=>{}, 1000);"'
      ],
      description:
          'Node.js 20 LTS JavaScript and TypeScript runtime environment with npm package manager.',
      notes:
          'Exec into the container or connect via Terminal to run Node applications, scripts, or build tools.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'python',
      name: 'Python 3.11 Runtime',
      category: 'Dev Environments',
      type: RecipeType.docker,
      author: 'Python Software Foundation',
      version: '3.11-alpine',
      iconCodePoint: 0xe6a8, // Icons.terminal
      image: 'python:3.11-alpine',
      command: [
        'sh',
        '-c',
        'python3 -c "import time; print(\'Python 3 Ready\'); time.sleep(999999)"'
      ],
      description:
          'Python 3 runtime pre-configured with pip for scripts, web backends, and data science utilities.',
      isCustom: false,
    ),

    // ── AI & ML ─────────────────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'ollama',
      name: 'Ollama LLM Engine',
      category: 'AI & ML',
      type: RecipeType.docker,
      author: 'Ollama / Alpine',
      version: 'latest',
      iconCodePoint: 0xe510, // Icons.psychology
      image: 'alpine/ollama:latest',
      ports: [
        {'host': 11434, 'container': 11434}
      ],
      description:
          'Run local open-source Large Language Models (Llama 3, Phi-3, Mistral, Gemma) directly on ARM64.',
      notes:
          'Lightweight build (~72 MB): CPU-optimized Alpine Ollama engine that downloads in seconds and saves disk space. API listens on port 11434. Pull small models like "ollama pull smollm:135m" to run on mobile.',
      isCustom: false,
    ),

    // ── Web & Cloud ─────────────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'nginx',
      name: 'Nginx Web Server',
      category: 'Web & Cloud',
      type: RecipeType.docker,
      author: 'Nginx Inc.',
      version: 'alpine',
      iconCodePoint: 0xe30d, // Icons.http
      image: 'nginx:alpine',
      ports: [
        {'host': 8088, 'container': 80}
      ],
      description:
          'High-performance HTTP server, reverse proxy, and static file server with minimal memory footprint.',
      notes:
          'Web server is live at http://localhost:8088. Access directly from Chrome on your phone.',
      isCustom: false,
    ),

    // ── Databases ───────────────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'postgres',
      name: 'PostgreSQL 16',
      category: 'Databases',
      type: RecipeType.docker,
      author: 'PostgreSQL Global Dev Group',
      version: '16-alpine',
      iconCodePoint: 0xe5e1, // Icons.storage
      image: 'postgres:16-alpine',
      ports: [
        {'host': 5432, 'container': 5432}
      ],
      env: [
        {'key': 'POSTGRES_PASSWORD', 'value': 'linxr'},
        {'key': 'POSTGRES_USER', 'value': 'postgres'}
      ],
      description:
          'World-class, enterprise-grade open-source relational SQL database system.',
      notes:
          'Connect on localhost:5432. Default username is "postgres" with password "linxr".',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'redis',
      name: 'Redis Cache',
      category: 'Databases',
      type: RecipeType.docker,
      author: 'Redis Ltd.',
      version: 'alpine',
      iconCodePoint: 0xe244, // Icons.flash_on
      image: 'redis:alpine',
      ports: [
        {'host': 6379, 'container': 6379}
      ],
      description:
          'Ultra-fast in-memory key-value data structure store, cache, and message broker.',
      notes:
          'Connect using redis-cli on localhost:6379 or link from your applications.',
      isCustom: false,
    ),

    // ── Networking & Tools ──────────────────────────────────────────────────
    const MarketplaceItem(
      id: 'tailscale',
      name: 'Tailscale Mesh VPN',
      category: 'Networking & Tools',
      type: RecipeType.script,
      author: 'Tailscale Inc.',
      version: 'latest',
      iconCodePoint: 0xe62e, // Icons.vpn_lock
      description:
          'Zero-config mesh VPN that creates a secure private wireguard network to access your Linxr VM from any device.',
      script:
          'curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --accept-routes',
      notes:
          'Review the execution output for the Tailscale login URL. Open the link to authorize the node to your tailnet.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'rust',
      name: 'Rust Toolchain',
      category: 'Dev Tools',
      type: RecipeType.script,
      author: 'Rust Project',
      version: 'stable',
      iconCodePoint: 0xe1b0, // Icons.build
      description:
          'Installs the official Rust compiler (rustc) and Cargo package manager natively in the Alpine VM.',
      script: 'apk update && apk add rust cargo',
      notes:
          'Verify installation in the Terminal tab using "rustc --version" and "cargo --version".',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'golang',
      name: 'Go Compiler (Golang)',
      category: 'Dev Tools',
      type: RecipeType.script,
      author: 'Google / Go Authors',
      version: '1.22+',
      iconCodePoint: 0xe000, // Icons.integration_instructions
      description:
          'Installs official Google Go compiler, runtime, and standard packages natively into the Alpine Linux VM.',
      script: 'apk update && apk add go',
      notes:
          'Verify installation in the Terminal tab using "go version".',
      isCustom: false,
    ),

    // ── Dual-Mode Telecom & Monitoring Recipes ──────────────────────────────
    const MarketplaceItem(
      id: 'zyvr-docker',
      name: 'Zyvr — Asterisk PBX (Docker)',
      category: 'Networking & Tools',
      type: RecipeType.docker,
      author: 'AI2TH / Asterisk',
      version: 'latest',
      iconCodePoint: 0xe4cf, // Icons.phone_in_talk
      image: 'andrius/asterisk:latest',
      ports: [
        {'host': 5060, 'container': 5060},
        {'host': 8088, 'container': 8088},
      ],
      description:
          'Containerized Asterisk 20 PBX telephony server. Run isolated SIP PBX in Docker or daemonless FastTrack OCI mode.',
      notes:
          'Runs Asterisk inside an isolated container. Connect SIP softphones to port 5060. WebRTC/HTTP listens on port 8088.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'zyvr-native',
      name: 'Zyvr — Asterisk PBX (Native Linux)',
      category: 'Networking & Tools',
      type: RecipeType.script,
      author: 'AI2TH / Asterisk',
      version: '20-alpine',
      iconCodePoint: 0xe4cf, // Icons.phone_in_talk
      description:
          'Full Asterisk 20 PBX telephony server installed natively into Alpine Linux. Features PJSIP SIP stack, SRTP encryption, voicemail, and WebRTC bridge with zero container overhead.',
      script:
          'sed -i "s/https:/http:/g" /etc/apk/repositories 2>/dev/null || true && apk update && apk add --no-cache asterisk asterisk-sample-config asterisk-sounds-en asterisk-srtp openssl python3 && mkdir -p /etc/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk && chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk /etc/asterisk && rc-update add asterisk default 2>/dev/null || true && (rc-service asterisk restart 2>/dev/null || asterisk -U asterisk -G asterisk) && echo "Zyvr Asterisk PBX installed successfully!"',
      ports: [
        {'host': 5060, 'container': 5060},
        {'host': 8088, 'container': 8088},
      ],
      notes:
          'Native Asterisk PBX listening on port 5060 (SIP UDP/TCP) and 8088 (HTTP/WebSockets). Connect any SIP softphone (Linphone, Zoiper, MicroSIP) to 127.0.0.1:5060.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'zabbix-docker',
      name: 'Zabbix Server & Web UI (Docker)',
      category: 'Kubernetes & DevOps',
      type: RecipeType.docker,
      author: 'Zabbix LLC',
      version: 'latest',
      iconCodePoint: 0xeb51, // Icons.monitor_heart
      image: 'zabbix/zabbix-appliance:latest',
      ports: [
        {'host': 8080, 'container': 80},
        {'host': 10051, 'container': 10051},
      ],
      description:
          'Complete Zabbix enterprise monitoring appliance with integrated Zabbix Server, Web Frontend, and SQLite storage.',
      notes:
          'Access the Zabbix Web UI at http://localhost:8080 in your mobile browser. Default login: Admin / zabbix.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'zabbix-native',
      name: 'Zabbix Agent (Native Linux)',
      category: 'Kubernetes & DevOps',
      type: RecipeType.script,
      author: 'Zabbix LLC',
      version: '7.0-lts',
      iconCodePoint: 0xeb51, // Icons.monitor_heart
      description:
          'Installs the official Zabbix monitoring agent daemon natively in Alpine Linux. Collects host CPU, memory, storage, network traffic, and process metrics.',
      script:
          'sed -i "s/https:/http:/g" /etc/apk/repositories 2>/dev/null || true && apk update && apk add --no-cache zabbix-agent zabbix-utils && rc-update add zabbix-agent default 2>/dev/null || true && (rc-service zabbix-agent restart 2>/dev/null || zabbix_agentd) && echo "Zabbix Agent running on port 10050!"',
      ports: [
        {'host': 10050, 'container': 10050},
      ],
      notes:
          'Zabbix agent listens on port 10050. Edit /etc/zabbix/zabbix_agentd.conf to set Server=<your-zabbix-server-ip> and Hostname=<node-name>.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'nginx-native',
      name: 'Nginx Web Server (Native Linux)',
      category: 'Web & Cloud',
      type: RecipeType.script,
      author: 'Nginx Inc. / Alpine',
      version: 'alpine',
      iconCodePoint: 0xe30d, // Icons.http
      description:
          'High-performance HTTP web server installed natively into Alpine Linux. Minimal memory usage (<5 MB) without container layers.',
      script:
          'sed -i "s/https:/http:/g" /etc/apk/repositories 2>/dev/null || true && apk update && apk add --no-cache nginx && rc-update add nginx default 2>/dev/null || true && rc-service nginx restart 2>/dev/null || nginx',
      ports: [
        {'host': 8088, 'container': 80},
      ],
      notes:
          'Native Nginx server is live at http://localhost:8088. Root document directory: /var/lib/nginx/html.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'postgres-native',
      name: 'PostgreSQL 16 (Native Linux)',
      category: 'Databases',
      type: RecipeType.script,
      author: 'PostgreSQL Global Dev Group',
      version: '16-alpine',
      iconCodePoint: 0xe5e1, // Icons.storage
      description:
          'Installs PostgreSQL 16 server and client tools natively into Alpine Linux. High-speed SQL engine running with direct system I/O.',
      script:
          'sed -i "s/https:/http:/g" /etc/apk/repositories 2>/dev/null || true && apk update && apk add --no-cache postgresql postgresql-contrib && /etc/init.d/postgresql setup 2>/dev/null || true && rc-update add postgresql default 2>/dev/null || true && rc-service postgresql restart 2>/dev/null || su - postgres -c "pg_ctl start -D /var/lib/postgresql/data" || true',
      ports: [
        {'host': 5432, 'container': 5432},
      ],
      notes:
          'Native PostgreSQL active on port 5432. Connect via "su - postgres -c psql" in Terminal.',
      isCustom: false,
    ),
    const MarketplaceItem(
      id: 'redis-native',
      name: 'Redis In-Memory Cache (Native Linux)',
      category: 'Databases',
      type: RecipeType.script,
      author: 'Redis Ltd. / Alpine',
      version: 'alpine',
      iconCodePoint: 0xe244, // Icons.flash_on
      description:
          'Ultra-fast in-memory key-value database installed natively into Alpine Linux. Zero container abstraction latency.',
      script:
          'sed -i "s/https:/http:/g" /etc/apk/repositories 2>/dev/null || true && apk update && apk add --no-cache redis && rc-update add redis default 2>/dev/null || true && rc-service redis restart 2>/dev/null || redis-server --daemonize yes',
      ports: [
        {'host': 6379, 'container': 6379},
      ],
      notes:
          'Native Redis server active on localhost:6379. Connect via "redis-cli" in Terminal.',
      isCustom: false,
    ),
  ];

  // ── Remote Community Marketplace (AI2TH/linxr-marketplace) ───────────────
  static const String remoteRepoUrl =
      'https://raw.githubusercontent.com/AI2TH/linxr-marketplace/main/recipes.json';
  static const String _kRemoteRecipesCacheKey = 'cached_remote_marketplace_recipes';
  static const String _kLastSyncTimestampKey = 'marketplace_last_sync_ts';

  static Future<List<MarketplaceItem>> getRemoteItems({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();

    if (forceRefresh) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        final uri = Uri.parse('$remoteRepoUrl?t=${DateTime.now().millisecondsSinceEpoch}');
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
        final response = await request.close().timeout(const Duration(seconds: 15));

        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final list = jsonDecode(body) as List<dynamic>;
          final items = list
              .map((e) => MarketplaceItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();

          await prefs.setString(_kRemoteRecipesCacheKey, body);
          await prefs.setInt(_kLastSyncTimestampKey, DateTime.now().millisecondsSinceEpoch);
          return items;
        }
      } catch (e) {
        debugPrint('Remote marketplace fetch notice: $e (using offline fallback)');
      }
    }

    final String? cachedJson = prefs.getString(_kRemoteRecipesCacheKey);
    if (cachedJson != null && cachedJson.isNotEmpty) {
      try {
        final list = jsonDecode(cachedJson) as List<dynamic>;
        return list
            .map((e) => MarketplaceItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {}
    }

    return [];
  }

  static Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kLastSyncTimestampKey);
    if (ts == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }

  static Future<List<MarketplaceItem>> getAllItems({bool refreshRemote = false}) async {
    final customItems = await getCustomItems();
    final remoteItems = await getRemoteItems(forceRefresh: refreshRemote);

    // Merge in priority order: built-in < remote community < user custom
    final Map<String, MarketplaceItem> itemMap = {};
    for (final item in builtInItems) {
      itemMap[item.id] = item;
    }
    for (final item in remoteItems) {
      itemMap[item.id] = item;
    }
    for (final item in customItems) {
      itemMap[item.id] = item;
    }

    return itemMap.values.toList();
  }

  static Future<List<MarketplaceItem>> getCustomItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonStr = prefs.getString(_kCustomRecipesKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];

      final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => MarketplaceItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      debugPrint('Error loading custom recipes: $e');
      return [];
    }
  }

  static Future<void> saveCustomItem(MarketplaceItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = await getCustomItems();
      final existingIndex = items.indexWhere((i) => i.id == item.id);

      final updatedItem = item.copyWith(isCustom: true);
      if (existingIndex >= 0) {
        items[existingIndex] = updatedItem;
      } else {
        items.add(updatedItem);
      }

      final jsonStr = jsonEncode(items.map((i) => i.toJson()).toList());
      await prefs.setString(_kCustomRecipesKey, jsonStr);
    } catch (e) {
      debugPrint('Error saving custom recipe: $e');
      rethrow;
    }
  }

  static Future<void> deleteCustomItem(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = await getCustomItems();
      items.removeWhere((i) => i.id == id);
      final jsonStr = jsonEncode(items.map((i) => i.toJson()).toList());
      await prefs.setString(_kCustomRecipesKey, jsonStr);
    } catch (e) {
      debugPrint('Error deleting custom recipe: $e');
      rethrow;
    }
  }

  static String exportRecipeToJson(MarketplaceItem item) {
    return const JsonEncoder.withIndent('  ').convert(item.toJson());
  }

  static MarketplaceItem importRecipeFromJson(String jsonStr) {
    final Map<String, dynamic> data =
        Map<String, dynamic>.from(jsonDecode(jsonStr) as Map);
    return MarketplaceItem.fromJson(data).copyWith(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      isCustom: true,
    );
  }

  static Future<void> deployDocker(
    MarketplaceItem item, {
    String? customName,
    List<Map<String, dynamic>>? customPorts,
    List<Map<String, String>>? customEnv,
  }) async {
    final name = (customName != null && customName.trim().isNotEmpty)
        ? customName.trim()
        : '${item.id}_${DateTime.now().millisecondsSinceEpoch % 10000}';
    final image = item.image ?? item.id;
    final ports = customPorts ?? item.ports;
    final env = customEnv ?? item.env;

    await VmPlatform.startContainer(
      image,
      name,
      item.command,
      ports: ports,
      env: env,
      network: item.network,
    );
  }

  static Future<Map<String, dynamic>> executeScript(String script) async {
    return await VmPlatform.vmExec(script);
  }

  static Future<void> stopContainer(String name) async {
    await VmPlatform.stopContainer(name);
  }

  static Future<String> getContainerLogs(String name, {int tail = 100}) async {
    return await VmPlatform.getLogs(name, tail);
  }
}
