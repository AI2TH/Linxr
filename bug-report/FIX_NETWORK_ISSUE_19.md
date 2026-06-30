# Detailed Fix Specification — Issue #19 (Network Drops) & Issue #18 (Kernel Update)

> **Branch**: `bugs-network-issue`
> **Repository**: `AI2TH/Linxr`
> **Priority**: High (Issue #19), Medium (Issue #18)

---

## Issue #19 — Network Drops Under High Concurrency

### Root Cause Analysis

The VM boots with a **single SLIRP (user-mode) netdev** defined in [VmManager.kt line 187](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L187):

```kotlin
cmd += listOf("-netdev", "user,id=net0,hostfwd=tcp::2222-:22")
```

There are **three compounding failures**:

1. **SLIRP has no DNS override** — the guest gets `10.0.2.3` (QEMU's built-in DNS proxy). This proxy is single-threaded and drops queries under concurrency. `npm install` fires 50+ parallel HTTP connections, each requiring DNS lookups.

2. **No TCP buffer tuning inside the guest** — Alpine musl's defaults are conservative. Under TCG (software CPU emulation), the guest is ~3× slower than native, so TCP retransmit timers expire before the guest can process packets.

3. **No `net.core.*` / `net.ipv4.*` sysctl tuning** — the guest kernel boots with default buffer sizes. Under high-concurrency workloads over a virtual NIC, small buffers cause packet drops at the kernel level.

### Fix Plan — 3 changes

---

#### Fix 1: Add SLIRP DNS + network tuning to QEMU command (Kotlin)

**File**: [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt)
**Location**: Line 187 inside `buildQemuCommand()`

**Current code** (line 187):
```kotlin
cmd += listOf("-netdev", "user,id=net0,hostfwd=tcp::2222-:22")
```

**Replace with**:
```kotlin
// SLIRP tuning:
// - dns=1.1.1.1       → bypass QEMU's single-threaded DNS proxy (10.0.2.3)
//                        and use Cloudflare's resolver directly. This fixes
//                        DNS query drops under high concurrency (npm install).
// - dnssearch=lan     → provide a search domain so short names still resolve.
// - hostfwd=tcp::2222-:22 → SSH port forwarding (unchanged).
cmd += listOf("-netdev",
    "user,id=net0," +
    "dns=1.1.1.1," +
    "dnssearch=lan," +
    "hostfwd=tcp::2222-:22"
)
```

**Why**: QEMU's `-netdev user` supports `dns=` to override the DNS server advertised to the guest via DHCP. By setting it to `1.1.1.1` (Cloudflare) or `8.8.8.8` (Google), we bypass QEMU's internal DNS proxy which is the single biggest source of packet drops.

---

#### Fix 2: Add guest-side network hardening to the bootstrap script

**File**: [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: Insert a new section **after** line 15 (after the filesystem expansion block) and **before** the "Set root password" block (line 18).

**Add this new block**:
```bash
# ---------------------------------------------------------------------------
# Network hardening for SLIRP user-mode networking (fixes Issue #19)
# ---------------------------------------------------------------------------
# QEMU's SLIRP stack is single-threaded and drops packets under high
# concurrency (e.g. npm install opening 50+ parallel connections).
# These sysctl settings increase kernel-level buffers and tune TCP to be
# more resilient under software emulation (TCG) latency.
echo "Tuning network for SLIRP compatibility..."

# --- DNS resilience ---
# Alpine musl libc respects /etc/resolv.conf. Force Cloudflare + Google DNS
# as fallback in case QEMU's DHCP-advertised DNS (set via -netdev dns=)
# doesn't take effect or the user is running an older QEMU build.
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:5 attempts:3 rotate
DNSEOF

# --- TCP buffer sizes ---
# Increase default and max socket buffer sizes.
# Default Alpine values (212992 bytes) are too small for bursty workloads
# over the virtio-net + SLIRP path. 4MB max / 1MB default handles npm bulk.
sysctl -w net.core.rmem_max=4194304      2>/dev/null || true
sysctl -w net.core.wmem_max=4194304      2>/dev/null || true
sysctl -w net.core.rmem_default=1048576  2>/dev/null || true
sysctl -w net.core.wmem_default=1048576  2>/dev/null || true

# --- TCP tuning ---
# Increase TCP buffer auto-tuning range: min=4KB, default=1MB, max=4MB
sysctl -w net.ipv4.tcp_rmem="4096 1048576 4194304"  2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 1048576 4194304"  2>/dev/null || true

# Reduce orphaned socket timeout — in an emulated environment, long
# TCP FIN_WAIT2 / TIME_WAIT states waste limited SLIRP connection slots.
sysctl -w net.ipv4.tcp_fin_timeout=15          2>/dev/null || true

# Enable TCP window scaling and timestamps for better throughput
sysctl -w net.ipv4.tcp_window_scaling=1        2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1            2>/dev/null || true

# Lower keepalive interval — detect dead SLIRP connections faster
sysctl -w net.ipv4.tcp_keepalive_time=60       2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_intvl=10      2>/dev/null || true
sysctl -w net.ipv4.tcp_keepalive_probes=5      2>/dev/null || true

# --- Connection tracking ---
# Increase the netfilter conntrack table size. SLIRP maps every guest TCP
# connection to a host socket; large npm installs can exhaust defaults.
sysctl -w net.netfilter.nf_conntrack_max=16384 2>/dev/null || true

# --- Persist via sysctl.conf for subsequent boots ---
cat >> /etc/sysctl.conf <<'SYSEOF'
# Linxr network tuning (Issue #19)
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

**Why each sysctl matters**:

| sysctl | Default | New Value | Reason |
|---|---|---|---|
| `net.core.rmem_max` | 212 KB | 4 MB | Prevents socket recv buffer from being too small for bursts |
| `net.core.wmem_max` | 212 KB | 4 MB | Prevents socket send buffer from being too small for bursts |
| `tcp_rmem` / `tcp_wmem` | 4K/87K/6MB | 4K/1M/4M | Raises the "default" middle value so each new connection gets 1MB |
| `tcp_fin_timeout` | 60s | 15s | Reclaims SLIRP connection slots faster after close |
| `tcp_keepalive_time` | 7200s | 60s | Detects dead SLIRP sockets in 60s instead of 2 hours |
| `tcp_keepalive_intvl` | 75s | 10s | Probes every 10s once keepalive kicks in |
| `resolv.conf` | `10.0.2.3` | `1.1.1.1`, `8.8.8.8` | Bypasses QEMU's single-threaded DNS proxy entirely |

---

#### Fix 3: Add npm/package-manager config guidance to bootstrap (optional)

**File**: [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh)
**Location**: Append after the network tuning block (before the "Set root password" section).

**Add**:
```bash
# ---------------------------------------------------------------------------
# npm / Node.js default configuration for SLIRP environments
# ---------------------------------------------------------------------------
# Pre-configure npm retry settings globally so that first-time users
# don't hit network timeout errors during `npm install`.
if command -v npm >/dev/null 2>&1 || [ -d /usr/lib/node_modules ]; then
    npm config set fetch-retry-maxtimeout 120000 2>/dev/null || true
    npm config set fetch-retry-mintimeout 20000  2>/dev/null || true
    npm config set fetch-retries 5               2>/dev/null || true
    echo "npm retry config set for SLIRP networking."
fi
```

**Why**: Even with sysctl tuning, TCG's CPU overhead means npm's default 10-second timeout can still expire. This pre-configures npm to retry more aggressively. The `if` guard ensures it only runs when Node.js is installed.

---

## Issue #18 — Kernel Update Stuck at 6.6.x

### Root Cause Analysis

In [VmManager.kt lines 194–203](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L194-L203), the QEMU command uses `-kernel` and `-initrd` flags:

```kotlin
val kernel = File(vmDir, "vmlinuz-virt")
val initrd = File(vmDir, "initramfs-virt")
if (kernel.exists() && initrd.exists()) {
    cmd += listOf("-kernel", kernel.absolutePath)
    cmd += listOf("-initrd", initrd.absolutePath)
    cmd += listOf("-append",
        "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rootflags=rw " +
        "modules=virtio_blk,ext4 quiet " +
        "cgroup_no_v1=all")
}
```

These files (`vmlinuz-virt`, `initramfs-virt`) are extracted from the APK's `assets/vm/` directory during [extractAssets()](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L220-L254) and overwritten every time `ASSETS_VERSION` changes. The guest's `apk upgrade` writes new kernel files to `/boot/` inside the guest disk — but QEMU never reads from `/boot/`. It always uses the host-side files.

### Fix Plan — Documentation-only (no code change needed)

This is **by design** — external kernel boot is required because:
1. The guest disk is a QCOW2 overlay; extracting a kernel from it at boot time would require mounting it on the host (impossible in Android sandbox).
2. The kernel must match the modules in `base.qcow2`. Mismatches cause boot panics.

**The fix is documentation and user education:**

#### Fix 4: Explain kernel lifecycle in README.md

**File**: [README.md](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/README.md)
**Location**: The existing Troubleshooting section (already added — see "Kernel Update Issue" heading).

Enhance the existing section with:
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

**What users can do**: Run `apk upgrade` to update userland packages (OpenSSH,
Python, etc.) — those changes persist across reboots. Only the kernel itself
requires an APK update.
```

---

## Summary of All Changes

| # | File | Type | Description |
|---|---|---|---|
| **Fix 1** | [VmManager.kt:187](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L187) | Code | Add `dns=1.1.1.1,dnssearch=lan` to SLIRP `-netdev` |
| **Fix 2** | [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh) (after line 15) | Code | Add DNS override + TCP sysctl tuning block |
| **Fix 3** | [init_bootstrap.sh](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/assets/bootstrap/init_bootstrap.sh) (after Fix 2) | Code (optional) | Pre-configure `npm` retry settings if Node.js is present |
| **Fix 4** | [README.md](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/README.md) | Docs | Expand kernel update explanation with maintainer steps |

## Testing Checklist

- [ ] Build APK with Fix 1 applied, boot VM, run `cat /etc/resolv.conf` — should show `1.1.1.1` instead of `10.0.2.3`
- [ ] SSH into VM, run `sysctl net.core.rmem_max` — should return `4194304`
- [ ] Run `npm install` on a mid-size project (e.g. `create-react-app`) — should complete without `ETIMEDOUT` or `EAI_AGAIN`
- [ ] Run `ping 1.1.1.1` from guest — should get replies without drops
- [ ] Run `apk update && apk upgrade` — should work without DNS failures
- [ ] Verify SSH still works on port 2222 after all changes
- [ ] Cold boot test: wipe `user.qcow2`, restart VM, verify bootstrap runs network tuning
