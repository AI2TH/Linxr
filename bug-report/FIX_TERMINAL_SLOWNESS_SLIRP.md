# Detailed Fix — Terminal Slowness / SLIRP Latency

> **Issue**: Even simple commands like `ls` are slow/delayed in the terminal
> **Branch**: `bugs-network-issue`
> **Root cause**: SSH-over-SLIRP round-trip latency + hidden SSH server misconfigurations

---

## Root Cause Analysis

The terminal uses this I/O path for **every single keystroke and output byte**:

```
Flutter TerminalView
    ↓ keystroke
dartssh2 SSHClient (Dart)
    ↓ SSH-encrypted TCP packet
Android loopback (127.0.0.1:2222)
    ↓
QEMU SLIRP stack (single-threaded, runs in QEMU main loop)
    ↓ de-encapsulate, NAT, forward to guest
Guest kernel virtio-net driver
    ↓
Guest sshd (OpenSSH)
    ↓ decrypt, execute command
/bin/sh → ls
    ↓ output goes back through the ENTIRE chain in reverse
```

There are **4 compounding problems**:

### Problem 1: `UseDNS yes` (default) — adds 2-5 seconds per interaction
OpenSSH's `sshd` does a **reverse DNS lookup** on every new connection to verify the client's IP. This DNS query goes through SLIRP's single-threaded DNS proxy (`10.0.2.3`), which is slow. Even cached lookups take 500ms+ under TCG.

**This is the #1 cause of perceived slowness.**

See: [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh) — line 38–45 configure sshd but **never disable DNS lookup**.

### Problem 2: GSSAPI authentication negotiation
sshd tries GSSAPI (Kerberos) authentication by default before falling back to password. On Alpine with no GSSAPI libraries, this causes a timeout/retry cycle, adding ~1s delay per connection.

### Problem 3: SSH encryption overhead under TCG
The guest CPU is software-emulated (TCG). SSH's AES-256 encryption/decryption for every packet is expensive. Each `ls` output line is encrypted by guest sshd (slow emulated CPU) → decrypted by dartssh2 (fast native CPU).

### Problem 4: SLIRP processes packets in QEMU's main loop
SLIRP doesn't run in its own thread. Every network packet is processed synchronously in the QEMU event loop, which is already busy with TCG translation. Under load, this creates I/O stalls.

---

## Fix Plan — 4 changes (ordered by impact)

---

### Fix 1: SSH server tuning in bootstrap (HIGHEST IMPACT — easy)

**File**: [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: After line 45 (after the existing sshd_config block), before the sudo section.

**Currently**, lines 37–45 only set `PermitRootLogin` and `PasswordAuthentication`. The following critical settings are **missing**.

**Add this block after line 45** (after `|| echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config`):

```bash
# ---------------------------------------------------------------------------
# SSH performance tuning for SLIRP/TCG environment (fixes terminal latency)
# ---------------------------------------------------------------------------
# UseDNS no:    Disables reverse DNS lookup on client IP.
#               DEFAULT is "yes" — causes 2-5s delay per connection because
#               the lookup goes through QEMU's single-threaded SLIRP DNS proxy.
#               This is the SINGLE BIGGEST latency fix.
#
# GSSAPIAuthentication no:  Disables Kerberos/GSSAPI auth negotiation.
#               No GSSAPI libs on Alpine, so this just adds timeout delays.
#
# ClientAliveInterval 15:   Sends keepalive every 15s to detect dead connections.
#               Prevents zombie sessions from accumulating in sshd.
#
# MaxStartups 10:3:20:  Accept up to 10 unauthenticated connections before
#               rate-limiting. Prevents connection drops when the Flutter app
#               opens multiple tabs rapidly.
#
# Compression no:  Disable SSH compression — all traffic is localhost, so
#               compression just wastes emulated CPU cycles.
#
# LoginGraceTime 30:  Reduce from default 120s — frees sshd resources faster
#               if a connection attempt hangs.
grep -q "^UseDNS" /etc/ssh/sshd_config \
    && sed -i 's/^UseDNS.*/UseDNS no/' /etc/ssh/sshd_config \
    || echo "UseDNS no" >> /etc/ssh/sshd_config

grep -q "^GSSAPIAuthentication" /etc/ssh/sshd_config \
    && sed -i 's/^GSSAPIAuthentication.*/GSSAPIAuthentication no/' /etc/ssh/sshd_config \
    || echo "GSSAPIAuthentication no" >> /etc/ssh/sshd_config

grep -q "^ClientAliveInterval" /etc/ssh/sshd_config \
    || echo "ClientAliveInterval 15" >> /etc/ssh/sshd_config

grep -q "^MaxStartups" /etc/ssh/sshd_config \
    || echo "MaxStartups 10:3:20" >> /etc/ssh/sshd_config

grep -q "^Compression" /etc/ssh/sshd_config \
    || echo "Compression no" >> /etc/ssh/sshd_config

grep -q "^LoginGraceTime" /etc/ssh/sshd_config \
    || echo "LoginGraceTime 30" >> /etc/ssh/sshd_config

echo "sshd performance tuning applied."
```

**Expected improvement**: `UseDNS no` alone should reduce per-command latency by **2-5 seconds**.

---

### Fix 2: Add virtio-serial console to QEMU (bypasses SLIRP entirely)

**File**: [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Inside `buildQemuCommand()`, after line 190 (after `virtio-rng-pci`).

virtio-serial creates a **direct memory-mapped channel** between the host and guest — completely bypassing SLIRP, TCP, and SSH. The data path becomes:

```
Flutter TerminalView
    ↓ raw bytes (no encryption needed — it's a local pipe)
Unix socket (host-side)
    ↓
QEMU virtio-serial device (memory-mapped, not network)
    ↓
Guest /dev/vport0p1
    ↓
getty or shell (direct console — no sshd needed)
```

**Add after line 190** (`cmd += listOf("-device", "virtio-rng-pci")`):

```kotlin
// ── virtio-serial console (bypasses SLIRP for terminal I/O) ──
// Creates a direct host↔guest pipe via shared memory, avoiding the
// SLIRP TCP/IP stack and SSH encryption overhead entirely.
// Guest side: /dev/vport0p1 (or /dev/hvc0 with virtconsole)
// Host side:  Unix socket at $vmDir/console.sock
val consoleSock = File(vmDir, "console.sock")
consoleSock.delete() // remove stale socket from previous run

cmd += listOf("-device", "virtio-serial-pci,id=virtio-serial0")
cmd += listOf("-chardev", "socket,id=console_ch,path=${consoleSock.absolutePath},server=on,wait=off")
cmd += listOf("-device", "virtconsole,chardev=console_ch,name=com.ai2th.linxr.console")
```

**And update the kernel `-append` line** (line 199–202) to load the `virtio_console` module:

**Current** (line 200-202):
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

---

### Fix 3: Add guest-side getty on virtio-console

**File**: [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: After the "Start SSH daemon" section (after line 64), before the "Verify sshd" block.

**Add**:
```bash
# ---------------------------------------------------------------------------
# Start a login shell on the virtio-serial console (bypasses SLIRP + SSH)
# ---------------------------------------------------------------------------
# /dev/hvc0 is the virtconsole device created by the virtio-serial-pci
# device in QEMU. Starting getty here gives the Flutter app a direct
# terminal channel that doesn't go through the network stack at all.
if [ -e /dev/hvc0 ]; then
    # Start getty on hvc0 — auto-login as root (no password prompt needed
    # since the console socket is local to the app's sandbox)
    setsid getty -n -l /bin/sh 115200 hvc0 &
    echo "virtio-console shell started on /dev/hvc0"
else
    echo "No /dev/hvc0 found — falling back to SSH-only access"
fi
```

---

### Fix 4: Connect Flutter terminal to virtio-serial socket

**File**: [terminal_screen.dart](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart)
**Location**: Modify `_connect()` method (line 252) to try the virtio-serial Unix socket first, then fall back to SSH.

> [!IMPORTANT]
> This fix requires the `dart:io` `Socket` class which is available on Android but works differently from dartssh2. The implementation needs a platform channel to connect to the Unix domain socket since Dart's `Socket` class doesn't support Unix sockets directly on Android.
>
> **Alternative approach**: Create a Kotlin-side method that bridges the Unix socket to a TCP port (e.g. `localhost:2223`), then connect dartssh2 to that port in raw mode. This is simpler to implement.

**Add to** [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) — a new method after `startVm()`:

```kotlin
/**
 * Bridges the virtio-serial Unix socket to a TCP port so that Dart code
 * can connect to it using standard sockets.
 *
 * The bridge runs on a daemon thread and forwards bytes bidirectionally:
 *   TCP client (localhost:2223) ↔ Unix socket (vm/console.sock)
 *
 * Returns the TCP port number, or -1 if the console socket doesn't exist.
 */
private var consoleBridge: Thread? = null

fun startConsoleBridge(): Int {
    val sock = File(vmDir, "console.sock")
    if (!sock.exists()) return -1

    val tcpPort = 2223
    consoleBridge = Thread {
        try {
            val server = java.net.ServerSocket(tcpPort, 1,
                java.net.InetAddress.getByName("127.0.0.1"))
            while (isRunning) {
                val tcpClient = server.accept()
                val unixChannel = java.nio.channels.SocketChannel.open(
                    java.net.UnixDomainSocketAddress.of(sock.absolutePath)
                )
                // Forward TCP→Unix
                Thread {
                    try {
                        tcpClient.getInputStream().copyTo(
                            java.nio.channels.Channels.newOutputStream(unixChannel))
                    } catch (_: Exception) {}
                }.apply { isDaemon = true; start() }
                // Forward Unix→TCP
                Thread {
                    try {
                        java.nio.channels.Channels.newInputStream(unixChannel).copyTo(
                            tcpClient.getOutputStream())
                    } catch (_: Exception) {}
                }.apply { isDaemon = true; start() }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Console bridge failed: ${e.message}")
        }
    }.apply { isDaemon = true; start() }
    return tcpPort
}
```

**Then in** [terminal_screen.dart](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart), modify `_connect()` (line 252):

```dart
Future<void> _connect(_Tab tab) async {
    if (tab.connState == _ConnState.connecting ||
        tab.connState == _ConnState.connected) return;

    setState(() => tab.connState = _ConnState.connecting);

    // Try virtio-console first (port 2223 — no SSH, no SLIRP, no encryption)
    try {
      tab.terminal.write('\r\nConnecting via virtio-console...\r\n');
      final socket = await Socket.connect('127.0.0.1', 2223)
          .timeout(const Duration(seconds: 2));

      // Raw socket — no SSH overhead
      socket.listen(
        (data) => tab.terminal.write(String.fromCharCodes(data)),
        onDone: () => _onSessionDone(tab),
      );
      tab.terminal.onOutput = (data) {
        socket.add(Uint8List.fromList(data.codeUnits));
      };
      tab.retryCount = 0;
      if (mounted) setState(() => tab.connState = _ConnState.connected);
      return; // Success — skip SSH
    } catch (_) {
      tab.terminal.write('\r\nvirtio-console unavailable, using SSH...\r\n');
    }

    // Fall back to SSH over SLIRP (existing code)
    tab.terminal.write('\r\nConnecting to Linxr...\r\n');
    // ... rest of existing SSH connection code ...
}
```

> [!NOTE]
> **Fix 4 (virtio-serial) is the advanced fix.** If time is limited, **Fix 1 alone** (`UseDNS no` + sshd tuning) will provide a major improvement. Fix 4 eliminates SLIRP from the terminal path entirely but requires more implementation work.

---

## Impact Summary

| Fix | Effort | Latency Reduction | What It Does |
|---|---|---|---|
| **Fix 1** — sshd tuning | 🟢 Easy (shell script only) | **~70% reduction** | Removes 2-5s DNS lookup delay, GSSAPI timeout, and SSH compression overhead |
| **Fix 2** — QEMU virtio-serial | 🟡 Medium (Kotlin) | Enables Fix 3-4 | Adds a direct host↔guest I/O channel that bypasses SLIRP |
| **Fix 3** — Guest getty on hvc0 | 🟢 Easy (shell script) | Enables Fix 4 | Starts a shell on the virtio-console device |
| **Fix 4** — Flutter socket bridge | 🟠 Hard (Kotlin + Dart) | **~95% reduction** | Terminal I/O goes through memory-mapped virtio, not network stack |

## Recommended Implementation Order

1. **Start with Fix 1** — it's a one-file change to `init_bootstrap.sh` and gives the biggest bang-for-buck
2. **Test** — if latency is acceptable after Fix 1, stop there
3. If more speed is needed, implement Fixes 2+3+4 together as a second PR

---

## Testing Checklist

- [ ] After Fix 1: SSH into VM, run `ls` — response should be near-instant (< 200ms)
- [ ] After Fix 1: Open 3 terminal tabs simultaneously — all should connect without delay
- [ ] After Fix 1: Run `cat /etc/ssh/sshd_config | grep -E "UseDNS|GSSAPI|Compression"` — verify settings
- [ ] After Fix 2: Check `ls /dev/hvc0` inside VM — device should exist
- [ ] After Fix 4: Terminal should show "Connecting via virtio-console" instead of SSH
- [ ] After Fix 4: Run `ls`, `cat /etc/os-release`, `top` — all should be noticeably faster than SSH
- [ ] Regression: SSH on port 2222 should still work (for external SSH clients like Termux)
