# Linxr — Improvements to Beat vmConsole

## Why vmConsole Lost

vmConsole was the only real competitor. It is now:
- **Removed from Play Store** (September 2022, no announcement)
- **Repo deleted** by author (hostile to community)
- **3.4/5 stars, 29 reviews** — tiny user base before it was pulled
- **QEMU 6.1** — 2 years outdated
- **x86_64 TCG emulation** — 10–25× slower than native ARM

Linxr already wins on the most important metric:
> Linxr emulates aarch64 on aarch64 → ~3× overhead
> vmConsole emulates x86_64 on aarch64 → 10–25× overhead

**Linxr is already 3–8× faster than vmConsole.** The gaps below are UI/UX, not fundamentals.

---

## Gaps to Close (vmConsole has, Linxr doesn't)

### 1. Host File Sharing (9P/VirtFS)
vmConsole exposes Android external storage into the VM via `virtio-9p-pci`.
Users mount it with `mount -t 9p host_storage /media/host`.

**Add to Linxr:**
```kotlin
// In buildQemuCommand():
cmd += listOf("-fsdev", "local,id=host,path=${context.getExternalFilesDir(null)},security_model=none")
cmd += listOf("-device", "virtio-9p-pci,fsdev=host,mount_tag=host_storage")
```
Inside Alpine, auto-mount in `/etc/fstab`:
```
host_storage  /media/host  9p  trans=virtio,version=9p2000.L,rw  0  0
```
This lets users drop files from Android into `/media/host` and access them instantly in the VM.

---

### 2. Port Forwarding UI
vmConsole hardcodes ports 22 and 80 only. Users complained they couldn't expose custom ports.

**Add to Linxr:**
- Settings screen with a list of port forward rules
- Default: `2222→22` (SSH)
- User can add/remove: `hostPort → guestPort, TCP/UDP, label`
- Stored in SharedPreferences, applied to QEMU command on next start

```kotlin
// Example dynamic hostfwd list:
portForwards.forEach { rule ->
    cmd += listOf("-netdev", "user,...,hostfwd=${rule.proto}::${rule.hostPort}-:${rule.guestPort}")
}
```

---

### 3. Settings Screen
vmConsole has zero settings. Everything hardcoded.

**Add to Linxr — Settings screen with:**

| Setting | Default | Notes |
|---------|---------|-------|
| RAM | 1024 MB | Slider 256–4096 MB |
| vCPU | 2 | Picker 1–4 |
| Font size | 14sp | Slider |
| Color theme | Dark | Dark / Light / Solarized / Monokai |
| Scrollback lines | 2000 | Slider |
| Custom DNS | 10.0.2.3 | Override SLIRP DNS |
| Boot on app start | Off | Auto-start VM when app opens |
| Keep screen on | Off | Wakelock while VM running |

Currently RAM and vCPU are in SharedPreferences but have no UI. Just need the screen.

---

### 4. Boot Progress Indicator
vmConsole shows nothing during boot — blank terminal until Alpine is ready.

**Add to Linxr:**
- Stream QEMU serial output to a log view during boot
- Show kernel messages + OpenRC service start lines
- Display "VM Ready" when sshd starts (detect `sshd started` in log)
- Send Android notification: "Linxr — VM is ready. SSH on port 2222"

```kotlin
// VmManager: instead of draining stdout silently, pipe to LiveData
_bootLog.postValue(line)
// Flutter: show scrolling boot log until state == running
```

---

### 5. SSH Key Management
vmConsole: no key management, manual only.

**Add to Linxr:**
- First-run wizard: generate Ed25519 keypair on device
- Automatically inject `authorized_keys` into VM on first boot
- Option to copy public key to clipboard
- Show fingerprint in About screen

---

### 6. Clipboard Bridge
vmConsole: no clipboard sync between Android and VM.

**Add to Linxr:**
- virtio-serial channel for clipboard: VM can push text to Android clipboard
- Simple helper script in VM: `clip() { cat | socat - /dev/vport0p1; }`
- Android side reads from virtio-serial and calls `ClipboardManager.setPrimaryClip()`

```kotlin
// QEMU command addition:
cmd += listOf("-device", "virtio-serial-pci")
cmd += listOf("-chardev", "socket,id=clip,path=${filesDir}/clip.sock,server=on,wait=off")
cmd += listOf("-device", "virtserialport,chardev=clip,name=clipboard")
```

---

## Improvements Beyond vmConsole

### 7. Upgrade QEMU to 8.x
vmConsole uses QEMU 6.1 (2021). Latest stable is QEMU 9.x.

Benefits:
- virtiofs (faster than 9P for host sharing)
- Better virtio-net performance
- Security fixes
- Better TCG performance

Rebuild `libqemu.so` from QEMU 8.2+ source.

---

### 8. Multiple Terminal Sessions (Native)
vmConsole: 1 session, you must use tmux.
Linxr: already has multi-tab SSH terminal — this is already an advantage.

**Improve further:**
- Add `+` button to open new SSH tab without going through menu
- Tab close button (×)
- Tab rename (long-press)
- Max tabs: configurable (default 5, up to 10)

---

### 9. Quick Commands / Shortcuts
vmConsole: none.

**Add to Linxr:**
- Swipe-up panel with quick command buttons
- Default shortcuts: `htop`, `df -h`, `ip addr`, `apk update`
- User-configurable: long-press to edit/delete

---

### 10. User-Selectable VM Storage Location
Currently all VM files (`base.qcow2`, `user.qcow2`, kernel, initramfs) are stored in the
app's private `filesDir` — invisible to Android's file manager, not accessible via USB,
and deleted if the app is uninstalled.

**Add to Linxr:**
- On first run (or in Settings): picker for where VM data lives
  - **Internal (default)** — `filesDir/vm/` (private, secure, current behaviour)
  - **External app storage** — `getExternalFilesDir("vm")` (visible in Files app under `Android/data/com.ai2th.linxr/`, survives reinstall)
  - **Custom folder** — `SAF DocumentsContract` picker, user chooses any folder on device or SD card

- Show current location + used/free space in Settings screen
- **Move VM** button — copies `user.qcow2` to new location, updates path, deletes old copy
- Warning dialog if chosen location has less than 2 GB free

**Why it matters:**
- Users can back up `user.qcow2` (their entire VM state) just by copying one file in the file manager
- SD card support — offload the ~150 MB base image + overlay to a microSD card
- USB transfer — connect phone to PC and pull the QCOW2 directly
- App reinstall no longer wipes the VM (if stored externally)

**Implementation:**
```kotlin
// VmManager: resolve paths from stored preference
val vmLocation = prefs.getString("vm_storage_location", "internal")
val vmDir = when (vmLocation) {
    "external" -> context.getExternalFilesDir("vm")!!
    "custom"   -> File(prefs.getString("vm_custom_path", "")!!)
    else       -> File(context.filesDir, "vm")
}
```

The `base.qcow2` (read-only backing file) and `user.qcow2` (overlay) both move together.
QEMU command uses absolute paths so location change is transparent to QEMU.

---

### 11. Play Store Presence + Active Updates
vmConsole is gone from Play Store. **Linxr is the only option.**

Action items:
- Keep targeting latest SDK (currently 35)
- Release update at least quarterly
- Respond to Play Store reviews
- GitHub Discussions open for feature requests

---

## Priority Order

| Priority | Feature | Effort | Impact |
|----------|---------|--------|--------|
| 1 | **Settings screen** (RAM/CPU/font) | Low | High — currently no UI for existing config |
| 2 | **Boot progress + "VM ready" notification** | Low | High — huge UX gap |
| 3 | **Host file sharing (9P/VirtFS)** | Medium | High — #1 requested feature type |
| 4 | **Port forwarding UI** | Medium | High — vmConsole's top complaint |
| 5 | **SSH key management** | Medium | Medium |
| 6 | **Quick commands panel** | Low | Medium |
| 7 | **User-selectable VM storage location** | Low | High — backup, SD card, USB transfer |
| 8 | **QEMU 8.x upgrade** | High | Medium (performance + security) |
| 9 | **Clipboard bridge** | High | Medium |

---

## What Linxr Already Wins On

| | vmConsole | Linxr |
|--|-----------|-------|
| Play Store | ❌ Removed | ✅ Active |
| QEMU arch | x86_64 TCG (10–25× slow) | aarch64 native (3× slow) |
| Terminal tabs | 1 (use tmux) | 5 tabs built-in |
| UI | Single terminal view | Flutter, 3-screen UI |
| SDK target | 32 (Android 12) | 35 (Android 15) |
| Source available | Fork only (author deleted) | Active repo |
| Community | Hostile author | Open |
| Font/zoom | Pinch-to-zoom | Pinch-to-zoom (xterm) |

---

*Improvements v1.1 — April 2026*
