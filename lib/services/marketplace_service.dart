import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/marketplace_item.dart';
import 'recipe_signature.dart';
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
          // Install without starting, add GODEBUG to the env file the k3s
          // OpenRC service sources (the installer overwrites it), then start,
          // so the server process itself gets tlsmlkem=0 (issue #30).
          'curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh - && mkdir -p /etc/rancher/k3s && (grep -q "^GODEBUG=" /etc/rancher/k3s/k3s.env 2>/dev/null || echo "GODEBUG=tlsmlkem=0" >> /etc/rancher/k3s/k3s.env) && /etc/init.d/k3s restart',
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
        // Host 8088 is Linxr's default forward to guest port 80 (VmManager),
        // so expose Asterisk's HTTP/ARI port 8088 on host 8089 (issue #31).
        {'host': 8089, 'container': 8088},
      ],
      description:
          'Containerized Asterisk 20 PBX telephony server. Run isolated SIP PBX in Docker or daemonless FastTrack OCI mode.',
      notes:
          'Runs Asterisk inside an isolated container. Connect SIP softphones to port 5060. WebRTC/HTTP listens on port 8088 inside the VM; add a port forward from phone port 8089 to VM port 8088 in Containers > Port forwarding (TCP only) to reach it from the phone (phone port 8088 already forwards to VM port 80).',
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
          'apk update && apk add --no-cache asterisk asterisk-sample-config asterisk-sounds-en asterisk-srtp openssl python3 && mkdir -p /etc/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk && chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk /etc/asterisk && rc-update add asterisk default 2>/dev/null || true && (rc-service asterisk restart 2>/dev/null || asterisk -U asterisk -G asterisk) && echo "Zyvr Asterisk PBX installed successfully!"',
      ports: [
        {'host': 5060, 'container': 5060},
        // Host 8088 is Linxr's default forward to guest port 80 (VmManager),
        // so expose Asterisk's HTTP/ARI port 8088 on host 8089 (issue #31).
        {'host': 8089, 'container': 8088},
      ],
      notes:
          'Native Asterisk PBX listening on port 5060 (SIP UDP/TCP) and 8088 (HTTP/WebSockets) inside the VM. Add TCP port forwards for 5060 and for phone port 8089 to VM port 8088 in Containers > Port forwarding (phone port 8088 already forwards to VM port 80), then connect any SIP softphone (Linphone, Zoiper, MicroSIP) to 127.0.0.1:5060.',
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
          'apk update && apk add --no-cache zabbix-agent zabbix-utils && rc-update add zabbix-agent default 2>/dev/null || true && (rc-service zabbix-agent restart 2>/dev/null || zabbix_agentd) && echo "Zabbix Agent running on port 10050!"',
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
          'apk update && apk add --no-cache nginx && rc-update add nginx default 2>/dev/null || true && rc-service nginx restart 2>/dev/null || nginx',
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
          'apk update && apk add --no-cache postgresql postgresql-contrib && /etc/init.d/postgresql setup 2>/dev/null || true && rc-update add postgresql default 2>/dev/null || true && rc-service postgresql restart 2>/dev/null || su - postgres -c "pg_ctl start -D /var/lib/postgresql/data" || true',
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
          'apk update && apk add --no-cache redis && rc-update add redis default 2>/dev/null || true && rc-service redis restart 2>/dev/null || redis-server --daemonize yes',
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
  static const String remoteSignatureUrl = '$remoteRepoUrl.sig';
  static const String _kRemoteRecipesCacheKey = 'cached_remote_marketplace_recipes';
  static const String _kRemoteSignatureCacheKey = 'cached_remote_marketplace_recipes_sig';
  static const String _kLastSyncTimestampKey = 'marketplace_last_sync_ts';

  /// SharedPreferences key: reject unsigned community catalogs. Off by
  /// default (warn only) until linxr-marketplace publishes recipes.json.sig.
  static const String requireSignedPrefKey = 'marketplace_require_signed';
  static const String _kApprovedScriptsKey = 'approved_recipe_scripts';

  /// Signature state of the community catalog last loaded (null: none loaded).
  static CatalogSignature? lastCatalogSignature;

  /// Why the last fetched catalog was not used, if it was rejected.
  static String? lastCatalogRejection;

  static Future<(int, List<int>)> _httpGet(HttpClient client, String url) async {
    final uri = Uri.parse('$url?t=${DateTime.now().millisecondsSinceEpoch}');
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
        .timeout(const Duration(seconds: 15));
    return (response.statusCode, bytes);
  }

  /// Parses a catalog if its signature state is acceptable; null otherwise.
  static List<MarketplaceItem>? _acceptCatalog(
      String body, String? sig, bool requireSigned) {
    final state = RecipeSignature.verify(utf8.encode(body), sig);
    lastCatalogSignature = state;
    if (!RecipeSignature.accept(state, requireSigned: requireSigned)) {
      lastCatalogRejection = state == CatalogSignature.invalid
          ? 'The community catalog signature is invalid; the catalog was not loaded.'
          : 'The community catalog is not signed and signed catalogs are required.';
      return null;
    }
    lastCatalogRejection = null;
    final list = jsonDecode(body) as List<dynamic>;
    return list.map((e) => _remoteItemFromJson(e as Map)).toList();
  }

  static Future<List<MarketplaceItem>> getRemoteItems({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final requireSigned = prefs.getBool(requireSignedPrefKey) ?? false;

    if (forceRefresh) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final (status, bytes) = await _httpGet(client, remoteRepoUrl);
        if (status == 200) {
          final body = utf8.decode(bytes);
          String? sig;
          try {
            final (sigStatus, sigBytes) = await _httpGet(client, remoteSignatureUrl);
            if (sigStatus == 200) sig = utf8.decode(sigBytes, allowMalformed: true);
          } catch (e) {
            debugPrint('Catalog signature fetch failed: $e');
          }
          final items = _acceptCatalog(body, sig, requireSigned);
          if (items != null) {
            await prefs.setString(_kRemoteRecipesCacheKey, body);
            if (sig != null) {
              await prefs.setString(_kRemoteSignatureCacheKey, sig);
            } else {
              await prefs.remove(_kRemoteSignatureCacheKey);
            }
            await prefs.setInt(_kLastSyncTimestampKey, DateTime.now().millisecondsSinceEpoch);
            return items;
          }
          debugPrint('Community catalog rejected: $lastCatalogRejection');
        }
      } catch (e) {
        debugPrint('Remote marketplace fetch notice: $e (using offline fallback)');
      } finally {
        client.close(force: true);
      }
    }

    // The cached copy is checked again, so turning on "require signed"
    // also hides a previously accepted unsigned catalog.
    final String? cachedJson = prefs.getString(_kRemoteRecipesCacheKey);
    if (cachedJson != null && cachedJson.isNotEmpty) {
      try {
        final items = _acceptCatalog(
            cachedJson, prefs.getString(_kRemoteSignatureCacheKey), requireSigned);
        if (items != null) return items;
      } catch (_) {}
    }

    return [];
  }

  // MarketplaceItem.fromJson defaults isCustom to true (right for imported
  // JSON), but community recipes are not the user's own: without this they
  // were counted under "My Custom" and showed a delete button that did nothing.
  static MarketplaceItem _remoteItemFromJson(Map e) =>
      MarketplaceItem.fromJson(Map<String, dynamic>.from(e))
          .copyWith(isCustom: false, isCommunity: true);

  static Future<DateTime?> getLastSyncTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kLastSyncTimestampKey);
    if (ts == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts);
  }

  /// Merges built-in, community and the user's own recipes.
  ///
  /// A community recipe can never replace a built-in one: whoever controls
  /// the remote catalog must not decide what a built-in id (e.g. "k3s")
  /// runs as root on every phone. Such entries are dropped. The user's own
  /// recipes still take precedence, as before.
  static List<MarketplaceItem> mergeCatalog(
    List<MarketplaceItem> builtIn,
    List<MarketplaceItem> remote,
    List<MarketplaceItem> custom,
  ) {
    final Map<String, MarketplaceItem> itemMap = {};
    for (final item in builtIn) {
      itemMap[item.id] = item;
    }
    for (final item in remote) {
      if (itemMap.containsKey(item.id)) {
        debugPrint('Ignoring community recipe "${item.id}": it would replace a built-in recipe');
        continue;
      }
      itemMap[item.id] = item.copyWith(isCommunity: true, isCustom: false);
    }
    for (final item in custom) {
      itemMap[item.id] = item;
    }
    return itemMap.values.toList();
  }

  static Future<List<MarketplaceItem>> getAllItems({bool refreshRemote = false}) async {
    final customItems = await getCustomItems();
    final remoteItems = await getRemoteItems(forceRefresh: refreshRemote);
    return mergeCatalog(builtInItems, remoteItems, customItems);
  }

  // ── Script review before the first run ──────────────────────────────────

  // Same rule as validate.js in AI2TH/linxr-marketplace: a script that edits
  // /etc/apk/repositories and mentions http:, or any http:// Alpine mirror.
  static final RegExp _apkRepositoriesPattern = RegExp(r'apk/repositories');
  static final RegExp _httpSchemePattern = RegExp(r'\bhttp:');
  static final RegExp _httpAlpineMirrorPattern = RegExp(r'''http://[^\s'"]*/alpine/''');

  /// Whether [script] switches apk to plain http (e.g. by rewriting
  /// /etc/apk/repositories with sed, or adding an http:// Alpine mirror).
  static bool downgradesApkToHttp(String script) =>
      (_apkRepositoriesPattern.hasMatch(script) && _httpSchemePattern.hasMatch(script)) ||
      _httpAlpineMirrorPattern.hasMatch(script);

  /// Whether the user already reviewed exactly this script for this recipe.
  static Future<bool> isScriptApproved(MarketplaceItem item) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kApprovedScriptsKey);
    if (raw == null) return false;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return map[item.id] == (item.script ?? '');
    } catch (_) {
      return false;
    }
  }

  static Future<void> approveScript(MarketplaceItem item) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> map = {};
    try {
      final raw = prefs.getString(_kApprovedScriptsKey);
      if (raw != null) map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    map[item.id] = item.script ?? '';
    await prefs.setString(_kApprovedScriptsKey, jsonEncode(map));
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
