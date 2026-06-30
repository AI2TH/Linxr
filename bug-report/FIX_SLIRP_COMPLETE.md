# Complete SLIRP Fix Specification — Issues #19, #18, and Terminal Latency

> **Branch**: `bugs-network-issue`
> **Repository**: [AI2TH/Linxr](https://github.com/AI2TH/Linxr)
> **Affects**: Terminal responsiveness, npm install reliability, kernel update docs

---

## Table of Contents

1. [Root Cause Analysis](#root-cause-analysis)
2. [Fix 1 — sshd Performance Tuning](#fix-1--sshd-performance-tuning-highest-impact)
3. [Fix 2 — QEMU SLIRP DNS Override](#fix-2--qemu-slirp-dns-override)
4. [Fix 3 — Guest TCP/Network Sysctl Tuning](#fix-3--guest-tcpnetwork-sysctl-tuning)
5. [Fix 4 — npm Retry Configuration](#fix-4--npm-retry-configuration)
6. [Fix 5 — QEMU virtio-serial Console Device](#fix-5--qemu-virtio-serial-console-device-advanced)
7. [Fix 6 — Flutter Terminal virtio-serial Connection](#fix-6--flutter-terminal-virtio-serial-connection-advanced)
8. [Fix 7 — Kernel Update Documentation](#fix-7--kernel-update-documentation-issue-18)
9. [Implementation Order](#implementation-order)
10. [Testing Checklist](#testing-checklist)

---

## Root Cause Analysis

All three issues stem from QEMU's **SLIRP user-mode networking** stack. SLIRP runs as a single-threaded TCP/IP implementation inside QEMU's main event loop, which is already busy with TCG (software CPU emulation).

### Current Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Android App (Flutter)                                      │
│  ┌──────────────┐    ┌──────────────┐                       │
│  │ TerminalView  │    │  VmState     │                       │
│  │ (xterm widget)│    │  (polling)   │                       │
│  └──────┬───────┘    └──────┬───────┘                       │
│         │ SSH (dartssh2)     │ SSH (pingSsh)                  │
│         ▼                    ▼                                │
│  ┌─────────────────────────────────────────┐                │
│  │       TCP 127.0.0.1:2222                │                │
│  └─────────────────┬───────────────────────┘                │
│                    │                                         │
│  ┌─────────────────▼───────────────────────┐                │
│  │          QEMU Process                    │                │
│  │  ┌───────────┐  ┌────────────────────┐  │                │
│  │  │ TCG Engine │  │ SLIRP Stack        │  │                │
│  │  │ (CPU emu)  │  │ (single-threaded)  │  │                │
│  │  │ ■■■■■■■■■  │  │ • TCP/IP in user   │  │                │
│  │  │ HIGH LOAD  │  │ • DNS proxy 10.0.2.3│ │                │
│  │  └───────────┘  │ • NAT translation   │  │                │
│  │                  │ ★ BOTTLENECK ★      │  │                │
│  │                  └────────┬───────────┘  │                │
│  │                           │               │                │
│  │  ┌────────────────────────▼─────────────┐│                │
│  │  │ Guest Alpine Linux                    ││                │
│  │  │  • sshd (UseDNS yes = SLOW)          ││                │
│  │  │  • npm install → 50+ TCP connections ││                │
│  │  │  • Small default TCP buffers         ││                │
│  │  └──────────────────────────────────────┘│                │
│  └──────────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

### Three Symptoms, One Root Cause

| Symptom | How SLIRP Causes It |
|---|---|
| **`ls` is slow** (terminal delay) | sshd does reverse DNS lookup on client IP → query goes through SLIRP's single-threaded DNS proxy → 2-5s delay. Also: SSH encryption is expensive on emulated CPU |
| **`npm install` fails** (Issue #19) | npm opens 50+ parallel HTTP connections → SLIRP drops packets under concurrency. DNS queries for `registry.npmjs.org` timeout through SLIRP DNS proxy |
| **Kernel can't upgrade** (Issue #18) | Not SLIRP-related — caused by `-kernel` flag in QEMU command. Documented below for completeness |

---

## Fix 1 — sshd Performance Tuning (HIGHEST IMPACT)

> **Fixes**: Terminal slowness (`ls` delayed, typing laggy)
> **Effort**: 🟢 Easy — shell script only
> **Expected improvement**: ~70% latency reduction (2-5s → <200ms per command)

**File**: [`init_bootstrap.sh`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: Insert after line 45 (after `|| echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config`), before the sudo section (line 47).

### What to add

```bash
# ---------------------------------------------------------------------------
# SSH performance tuning for SLIRP/TCG environment
# ---------------------------------------------------------------------------
# Problem: Even simple commands like `ls` have 2-5 second delays.
#
# UseDNS no             → #1 fix. Disables reverse DNS lookup on client IP.
#                          Default "yes" sends DNS query through SLIRP's
#                          single-threaded proxy, adding 2-5s per connection.
#
# GSSAPIAuthentication no → Disables Kerberos negotiation. No GSSAPI libs on
#                           Alpine, so this just adds a timeout cycle (~1s).
#
# Compression no        → All traffic is localhost. Compression wastes
#                          emulated CPU cycles for zero benefit.
#
# ClientAliveInterval 15 → Sends keepalive every 15s. Detects dead SLIRP
#                          connections and frees sshd resources.
#
# MaxStartups 10:3:20   → Accept up to 10 unauthenticated connections.
#                          Prevents drops when opening multiple terminal tabs.
#
# LoginGraceTime 30     → Reduced from 120s default. Frees sshd resources
#                          faster if a connection attempt hangs.

grep -q "^UseDNS" /etc/ssh/sshd_config \
    && sed -i 's/^UseDNS.*/UseDNS no/' /etc/ssh/sshd_config \
    || echo "UseDNS no" >> /etc/ssh/sshd_config

grep -q "^GSSAPIAuthentication" /etc/ssh/sshd_config \
    && sed -i 's/^GSSAPIAuthentication.*/GSSAPIAuthentication no/' /etc/ssh/sshd_config \
    || echo "GSSAPIAuthentication no" >> /etc/ssh/sshd_config

grep -q "^Compression" /etc/ssh/sshd_config \
    || echo "Compression no" >> /etc/ssh/sshd_config

grep -q "^ClientAliveInterval" /etc/ssh/sshd_config \
    || echo "ClientAliveInterval 15" >> /etc/ssh/sshd_config

grep -q "^MaxStartups" /etc/ssh/sshd_config \
    || echo "MaxStartups 10:3:20" >> /etc/ssh/sshd_config

grep -q "^LoginGraceTime" /etc/ssh/sshd_config \
    || echo "LoginGraceTime 30" >> /etc/ssh/sshd_config

echo "sshd performance tuning applied."
```

### Why `UseDNS no` is the single biggest fix

When an SSH client connects, sshd calls `getnameinfo()` on the client's IP address to do a reverse DNS lookup. In a SLIRP environment:
1. Client IP is `10.0.2.2` (SLIRP gateway)
2. sshd sends PTR query for `2.0.0.10.in-addr.arpa` to `10.0.2.3` (SLIRP DNS proxy)
3. SLIRP DNS proxy forwards to Android's resolver
4. Android resolver tries to resolve this nonsense PTR record
5. Times out after 2-5 seconds
6. sshd finally proceeds with authentication

This happens on **every connection** — including the keepalive pings from the Flutter app.

---

## Fix 2 — QEMU SLIRP DNS Override

> **Fixes**: npm install DNS failures (Issue #19) + reinforces Fix 1
> **Effort**: 🟢 Easy — single line change in Kotlin

**File**: [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Line 187 inside `buildQemuCommand()`

### Current code (line 187)

```kotlin
cmd += listOf("-netdev", "user,id=net0,hostfwd=tcp::2222-:22")
```

### Replace with

```kotlin
// SLIRP DNS override: bypass QEMU's single-threaded DNS proxy (10.0.2.3)
// and advertise Cloudflare DNS (1.1.1.1) directly via DHCP.
// This fixes:
//   - npm install DNS timeouts (registry.npmjs.org lookups drop under concurrency)
//   - sshd reverse DNS delays (reinforces UseDNS=no in sshd_config)
//   - apk update/upgrade DNS failures
// dnssearch=lan provides a search domain so short hostnames still resolve.
cmd += listOf("-netdev",
    "user,id=net0," +
    "dns=1.1.1.1," +
    "dnssearch=lan," +
    "hostfwd=tcp::2222-:22"
)
```

### How it works

QEMU's `-netdev user` runs a DHCP server that advertises a DNS server to the guest. By default, it advertises `10.0.2.3` (QEMU's internal DNS proxy). The `dns=1.1.1.1` option changes the advertised DNS server so the guest resolves names directly through Cloudflare, bypassing SLIRP's single-threaded proxy entirely.

---

## Fix 3 — Guest TCP/Network Sysctl Tuning

> **Fixes**: npm install packet drops, connection resets, TCP timeouts (Issue #19)
> **Effort**: 🟢 Easy — shell script

**File**: [`init_bootstrap.sh`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: Insert after Fix 1's sshd tuning block, before the sudo section.

### What to add

```bash
# ---------------------------------------------------------------------------
# Network hardening for SLIRP user-mode networking (Issue #19)
# ---------------------------------------------------------------------------
# QEMU's SLIRP stack is single-threaded and drops packets under high
# concurrency (e.g. npm install opening 50+ parallel HTTP connections).
# These sysctl settings increase kernel-level buffers and tune TCP to
# be more resilient under software emulation (TCG) latency.
echo "Tuning network stack for SLIRP compatibility..."

# --- DNS resilience ---
# Force Cloudflare + Google DNS as fallback in case QEMU's DHCP-advertised
# DNS (set via -netdev dns=) doesn't take effect or user runs older QEMU.
# Also sets timeout/retry options for musl's resolver.
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:5 attempts:3 rotate
DNSEOF

# --- TCP buffer sizes ---
# Increase default and max socket buffer sizes.
# Alpine defaults (212992 bytes) are too small for bursty workloads
# over the virtio-net + SLIRP path. 4MB max / 1MB default handles npm.
sysctl -w net.core.rmem_max=4194304      2>/dev/null || true
sysctl -w net.core.wmem_max=4194304      2>/dev/null || true
sysctl -w net.core.rmem_default=1048576  2>/dev/null || true
sysctl -w net.core.wmem_default=1048576  2>/dev/null || true

# --- TCP auto-tuning range ---
# min=4KB, default=1MB, max=4MB (per-connection buffers)
sysctl -w net.ipv4.tcp_rmem="4096 1048576 4194304"  2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 1048576 4194304"  2>/dev/null || true

# --- TCP timer tuning ---
# Reduce FIN_WAIT2 timeout — in emulated environments, long TCP
# TIME_WAIT states waste limited SLIRP connection slots.
sysctl -w net.ipv4.tcp_fin_timeout=15          2>/dev/null || true

# Enable TCP window scaling and timestamps for better throughput
sysctl -w net.ipv4.tcp_window_scaling=1        2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1            2>/dev/null || true

# Lower keepalive — detect dead SLIRP connections faster
sysctl -w net.ipv4.tcp_keepalive_time=60       2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_intvl=10      2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_probes=5      2>/dev/null || true

# --- Connection tracking ---
# Increase conntrack table. SLIRP maps every guest TCP connection to
# a host socket; large npm installs can exhaust defaults.
sysctl -w net.netfilter.nf_conntrack_max=16384 2>/dev/null || true

# --- Persist for subsequent boots ---
cat >> /etc/sysctl.conf <<'SYSEOF'
# Linxr SLIRP network tuning
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.tcp_rmem=4096 1048576 4194304
net.ipv4.tcp_wmem=4096 1048576 4194304
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
SYSEOF

echo "Network tuning applied."
```

### Sysctl Reference

| sysctl | Alpine Default | New Value | Why |
|---|---|---|---|
| `net.core.rmem_max` | 212 KB | 4 MB | Larger recv buffers prevent drops during npm's bursty downloads |
| `net.core.wmem_max` | 212 KB | 4 MB | Larger send buffers prevent stalls on outgoing requests |
| `tcp_rmem` (default) | 87 KB | 1 MB | Each new TCP connection gets 1MB buffer instead of 87KB |
| `tcp_fin_timeout` | 60s | 15s | Reclaims SLIRP connection slots 4× faster after close |
| `tcp_keepalive_time` | 7200s (2hr) | 60s | Detects dead SLIRP sockets in 60s instead of 2 hours |
| `tcp_keepalive_intvl` | 75s | 10s | Probes every 10s once keepalive kicks in |
| `resolv.conf` | `10.0.2.3` | `1.1.1.1` + `8.8.8.8` | Bypasses QEMU's single-threaded DNS proxy entirely |

---

## Fix 4 — npm Retry Configuration

> **Fixes**: npm install timeouts even after TCP tuning (Issue #19)
> **Effort**: 🟢 Easy — shell script

**File**: [`init_bootstrap.sh`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: After Fix 3's network tuning block.

### What to add

```bash
# ---------------------------------------------------------------------------
# npm / Node.js retry configuration for SLIRP environments
# ---------------------------------------------------------------------------
# Even with TCP tuning, TCG's CPU overhead means npm's default 10-second
# fetch timeout can still expire under load. Pre-configure npm to retry
# more aggressively. Only runs if npm/Node.js is installed.
if command -v npm >/dev/null 2>&1 || [ -d /usr/lib/node_modules ]; then
    npm config set fetch-retry-maxtimeout 120000 2>/dev/null || true
    npm config set fetch-retry-mintimeout 20000  2>/dev/null || true
    npm config set fetch-retries 5               2>/dev/null || true
    echo "npm retry config set for SLIRP networking."
fi
```

---

## Fix 5 — QEMU virtio-serial Console Device (ADVANCED)

> **Fixes**: Terminal latency at the architecture level — eliminates SLIRP from terminal I/O path
> **Effort**: 🟡 Medium — Kotlin + shell script
> **Expected improvement**: ~95% latency reduction vs SSH-over-SLIRP

### Concept

virtio-serial creates a **direct memory-mapped channel** between host and guest, completely bypassing SLIRP, TCP, SSH, and encryption:

```
CURRENT (slow):                         AFTER FIX (fast):
Flutter → dartssh2 → TCP                Flutter → raw socket
  → SLIRP (bottleneck) → sshd            → QEMU virtio-serial (memory-mapped)
  → /bin/sh → output back                → /dev/hvc0 → getty → /bin/sh
  through entire chain                    → output back through same pipe
  
~6 hops, encrypted, through SLIRP       ~3 hops, raw bytes, no network stack
```

### Part A: Add virtio-serial device to QEMU command

**File**: [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Inside `buildQemuCommand()`, after line 190 (`virtio-rng-pci`).

**Add**:
```kotlin
// ── virtio-serial console (bypasses SLIRP for terminal I/O) ──────────
// Creates a direct host↔guest pipe via shared memory.
// Guest side: /dev/hvc0 (virtio console)
// Host side:  Unix socket at $vmDir/console.sock
val consoleSock = File(vmDir, "console.sock")
consoleSock.delete() // remove stale socket from previous run

cmd += listOf("-device", "virtio-serial-pci,id=virtio-serial0")
cmd += listOf("-chardev", "socket,id=console_ch,path=${consoleSock.absolutePath},server=on,wait=off")
cmd += listOf("-device", "virtconsole,chardev=console_ch,name=com.ai2th.linxr.console")
```

### Part B: Add `virtio_console` to kernel modules

**File**: [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Line 200-202 (kernel `-append` string).

**Current**:
```kotlin
"console=ttyAMA0 root=/dev/vda rootfstype=ext4 rootflags=rw " +
"modules=virtio_blk,ext4 quiet " +
"cgroup_no_v1=all"
```

**Replace with**:
```kotlin
"console=ttyAMA0 root=/dev/vda rootfstype=ext4 rootflags=rw " +
"modules=virtio_blk,virtio_console,ext4 quiet " +
"cgroup_no_v1=all"
```

### Part C: Start getty on the virtio-console device

**File**: [`init_bootstrap.sh`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: After the "Start SSH daemon" section (after line 64), before "Verify sshd".

**Add**:
```bash
# ---------------------------------------------------------------------------
# Start shell on virtio-serial console (bypasses SLIRP + SSH entirely)
# ---------------------------------------------------------------------------
# /dev/hvc0 is the virtconsole device. Starting getty here gives the
# Flutter app a direct terminal channel with no network stack involved.
if [ -e /dev/hvc0 ]; then
    # Auto-login as root — the console socket is local to the app sandbox,
    # so no password is needed (same security model as -serial stdio).
    setsid getty -n -l /bin/sh 115200 hvc0 &
    echo "virtio-console shell started on /dev/hvc0"
else
    echo "No /dev/hvc0 found — SSH-only mode"
fi
```

---

## Fix 6 — Flutter Terminal virtio-serial Connection (ADVANCED)

> **Fixes**: Connects the Flutter terminal UI to virtio-serial instead of SSH
> **Effort**: 🟠 Hard — Kotlin + Dart changes

### Part A: TCP-to-Unix-socket bridge (Kotlin side)

Dart's `Socket` class doesn't support Unix domain sockets on Android directly. So we create a Kotlin-side bridge that forwards TCP port 2223 to the Unix socket.

**File**: [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Add new method after `startVm()` (after line 110).

**Add**:
```kotlin
// ─── virtio-serial console bridge ────────────────────────────────────
// Bridges the Unix socket (console.sock) to TCP port 2223 so that
// Dart code can connect using standard Socket.connect().
//
// Data path: Dart Socket(2223) ↔ TCP bridge ↔ Unix socket ↔ QEMU virtio-serial ↔ guest /dev/hvc0
// This completely bypasses SLIRP and SSH.
private var consoleBridgeThread: Thread? = null
private val CONSOLE_TCP_PORT = 2223

fun startConsoleBridge(): Int {
    val sock = File(vmDir, "console.sock")
    if (!sock.exists()) {
        Log.w(TAG, "console.sock not found, bridge not started")
        return -1
    }

    consoleBridgeThread = Thread {
        try {
            val server = java.net.ServerSocket(CONSOLE_TCP_PORT, 1,
                java.net.InetAddress.getByName("127.0.0.1"))
            Log.d(TAG, "Console bridge listening on TCP $CONSOLE_TCP_PORT")

            while (isRunning) {
                val tcpClient = server.accept()
                Log.d(TAG, "Console bridge: client connected")

                val unixAddr = java.net.UnixDomainSocketAddress.of(sock.absolutePath)
                val unixChannel = java.nio.channels.SocketChannel.open(unixAddr)

                // TCP → Unix (keystrokes from Flutter to guest shell)
                Thread {
                    try {
                        val buf = ByteArray(4096)
                        val input = tcpClient.getInputStream()
                        val output = java.nio.channels.Channels.newOutputStream(unixChannel)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            output.flush()
                        }
                    } catch (_: Exception) {
                    } finally {
                        tcpClient.close()
                    }
                }.apply { isDaemon = true; name = "console-tcp2unix"; start() }

                // Unix → TCP (shell output from guest to Flutter)
                Thread {
                    try {
                        val buf = ByteArray(4096)
                        val input = java.nio.channels.Channels.newInputStream(unixChannel)
                        val output = tcpClient.getOutputStream()
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                            output.flush()
                        }
                    } catch (_: Exception) {
                    } finally {
                        unixChannel.close()
                    }
                }.apply { isDaemon = true; name = "console-unix2tcp"; start() }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Console bridge failed: ${e.message}")
        }
    }.apply { isDaemon = true; name = "console-bridge"; start() }

    return CONSOLE_TCP_PORT
}
```

**Also**: Call `startConsoleBridge()` from `startVm()`, after the process is launched (after line 109):
```kotlin
Log.d(TAG, "VM process launched")

// Start the virtio-serial bridge after a short delay to let QEMU create the socket
Thread {
    Thread.sleep(2000) // wait for QEMU to create console.sock
    val port = startConsoleBridge()
    if (port > 0) Log.d(TAG, "Console bridge ready on TCP port $port")
}.apply { isDaemon = true; start() }
```

**And** expose it via the MethodChannel. In `MainActivity.kt`, add:
```kotlin
"getConsolePort" -> {
    val port = vmManager.startConsoleBridge()
    result.success(port)
}
```

### Part B: Terminal tries virtio-console first, falls back to SSH

**File**: [`terminal_screen.dart`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart)
**Location**: Replace the `_connect()` method (line 252–299).

**Replace with**:
```dart
Future<void> _connect(_Tab tab) async {
    if (tab.connState == _ConnState.connecting ||
        tab.connState == _ConnState.connected) return;

    setState(() => tab.connState = _ConnState.connecting);

    // ── Try virtio-console first (port 2223) ──────────────────────────
    // This path bypasses SLIRP entirely: raw bytes go through
    // virtio-serial memory-mapped I/O, no SSH encryption, no TCP/IP.
    try {
      tab.terminal.write('\r\nConnecting via virtio-console...\r\n');
      final socket = await Socket.connect('127.0.0.1', 2223)
          .timeout(const Duration(seconds: 2));

      socket.listen(
        (data) => tab.terminal.write(String.fromCharCodes(data)),
        onDone: () => _onSessionDone(tab),
        onError: (_) => _onSessionDone(tab),
      );
      tab.terminal.onOutput = (data) {
        socket.add(Uint8List.fromList(data.codeUnits));
      };

      tab.retryCount = 0;
      if (mounted) setState(() => tab.connState = _ConnState.connected);
      tab.terminal.write('\r\n'); // trigger shell prompt
      return; // ✓ connected via virtio-console — skip SSH
    } catch (_) {
      tab.terminal.write('\r\nvirtio-console unavailable, using SSH...\r\n');
    }

    // ── Fall back to SSH over SLIRP ───────────────────────────────────
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
      tab.startKeepAlive(() => _onSessionDone(tab));
      if (mounted) setState(() => tab.connState = _ConnState.connected);
    } on TimeoutException {
      _retryOrError(tab, 'Timed out (${tab.retryCount + 1}/${_Tab._maxRetries})');
    } catch (e) {
      _retryOrError(tab, 'Failed: $e');
    }
}
```

**Note**: Add `import 'dart:io';` at the top of the file for `Socket`.

---

## Fix 7 — Kernel Update Documentation (Issue #18)

> **Fixes**: User confusion about kernel upgrade (Issue #18)
> **Effort**: 🟢 Easy — docs only

**File**: [`README.md`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/README.md)
**Location**: Replace the existing kernel troubleshooting section (around line 180) with:

```markdown
### 2. Can't upgrade the Linux kernel inside the VM (stuck at `6.6.x`, Issue #18)

The VM boots using QEMU's `-kernel` and `-initrd` flags, which load
`vmlinuz-virt` and `initramfs-virt` from the APK's bundled assets — **not**
from the guest's `/boot/` directory. This is by design:

- The host-side kernel must match the modules compiled into `base.qcow2`.
  A mismatch causes a kernel panic at boot.
- Android's app sandbox prevents mounting the QCOW2 overlay to extract
  a guest-side kernel before QEMU starts.

**To upgrade the kernel**, the project maintainer must:

1. Build a new Alpine rootfs with the desired kernel version using
   `scripts/build_qcow2.sh`.
2. Copy the matching `vmlinuz-virt` and `initramfs-virt` into
   `android/app/src/main/assets/vm/`.
3. Bump `ASSETS_VERSION` in `VmManager.kt` (currently `"v26"`).
4. Build and release a new APK.

**What users can do**: Run `apk upgrade` to update userland packages
(OpenSSH, Python, etc.) — those changes persist across reboots.
Only the kernel itself requires an APK update.
```

---

## Implementation Order

```
Priority 1 (do first — easy, high impact):
┌─────────────────────────────────────────┐
│ Fix 1: sshd tuning (UseDNS no)         │ ← biggest terminal speedup
│ Fix 2: QEMU dns=1.1.1.1                │ ← biggest npm speedup
│ Fix 3: TCP sysctl tuning               │ ← reinforces Fix 2
│ Fix 4: npm retry config                │ ← safety net for npm
│ Fix 7: Kernel docs (README)            │ ← just documentation
└─────────────────────────────────────────┘
     All in init_bootstrap.sh + 1 line in VmManager.kt
     Test here — if terminal is fast enough, STOP.

Priority 2 (do if still slow — more complex):
┌─────────────────────────────────────────┐
│ Fix 5: QEMU virtio-serial device       │ ← VmManager.kt + bootstrap
│ Fix 6: Flutter terminal socket bridge   │ ← VmManager.kt + Dart
└─────────────────────────────────────────┘
     Eliminates SLIRP from terminal path entirely
```

---

## Files Changed Summary

| File | Fixes | Changes |
|---|---|---|
| [`init_bootstrap.sh`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh) | 1, 3, 4, 5C | sshd config, TCP sysctl, npm config, getty on hvc0 |
| [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) L187 | 2 | Add `dns=1.1.1.1,dnssearch=lan` to `-netdev` |
| [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) L190+ | 5A | Add `virtio-serial-pci` + `virtconsole` chardev |
| [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) L200 | 5B | Add `virtio_console` to kernel modules |
| [`VmManager.kt`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) L110+ | 6A | Console bridge method + start call |
| [`terminal_screen.dart`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart) L252 | 6B | Try virtio-console first, fall back to SSH |
| [`README.md`](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/README.md) L180 | 7 | Expanded kernel update docs |

---

## Testing Checklist

### Priority 1 tests (Fixes 1-4)
- [ ] SSH into VM, run `ls` — response should be < 200ms (was 2-5s)
- [ ] Run `cat /etc/ssh/sshd_config | grep -E "UseDNS|GSSAPI|Compression"` — verify all set
- [ ] Run `sysctl net.core.rmem_max` — should return `4194304`
- [ ] Run `cat /etc/resolv.conf` — should show `1.1.1.1`, not `10.0.2.3`
- [ ] Run `ping 1.1.1.1` — should get replies without drops
- [ ] Run `apk update` — should complete without DNS errors
- [ ] Run `npm install` on a mid-size project — should complete without `ETIMEDOUT`
- [ ] Open 3 terminal tabs simultaneously — all should connect quickly

### Priority 2 tests (Fixes 5-6)
- [ ] Run `ls /dev/hvc0` inside VM — device should exist
- [ ] Terminal should show "Connecting via virtio-console..." on connect
- [ ] Run `ls`, `cat /etc/os-release`, `top` — should be noticeably faster than SSH
- [ ] Regression: SSH on port 2222 must still work (for external clients)
- [ ] Cold boot test: wipe `user.qcow2`, restart VM, verify all tuning applies
