# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Linxr** is an Android app that runs a full Alpine Linux VM (via QEMU) without root access. The key trick: QEMU is packaged as a native `.so` in the APK's `jniLibs/`, which Android's package manager installs with the `exec_type` SELinux label—allowing direct execution under the app's UID.

## Build Commands

All builds run inside Docker; no local Flutter/Java/Android SDK required.

```bash
# Build Alpine base disk image (qcow2)
bash scripts/build_qcow2.sh

# Build debug APK
bash scripts/build_apk.sh debug

# Build release APK
bash scripts/build_apk.sh release

# Install on connected device
adb install build/linxr-debug.apk
```

For local Flutter development (requires Flutter 3.0+ and Android SDK 35):
```bash
flutter pub get
flutter build apk --debug
```

## Architecture

The app has three distinct layers communicating through well-defined boundaries:

### Flutter UI (Dart) — `lib/`
Four screens: Home (VM start/stop), Terminal (SSH sessions), Settings (resources), About. State is managed via `provider` + `VmState` (`lib/services/vm_platform.dart`), a `ChangeNotifier` that polls VM status over a `MethodChannel` every 5 seconds. SSH terminal sessions use `dartssh2` + `xterm` widgets.

### Kotlin Android Layer — `android/app/src/main/kotlin/com/ai2th/linxr/`
- `VmManager.kt` — core: asset extraction, QEMU command builder, process lifecycle
- `MainActivity.kt` — `MethodChannel` handler (`com.ai2th.linxr/vm`), routes Dart calls to `VmManager` on an executor thread
- `VmService.kt` — foreground service holding a wakelock so QEMU isn't killed under memory pressure
- `AlpineApp.kt` — Application singleton that holds `VmManager` across activity recreation

### QEMU / Guest VM
`libqemu.so` is spawned via `ProcessBuilder` with `LD_LIBRARY_PATH` pointing to the native library dir. Networking is SLIRP user-mode NAT (no TAP/root needed), with port 2222 on the host forwarded to guest port 22. Disk layout: `base.qcow2` (read-only base) + `user.qcow2` (read-write overlay), keeping the base clean while persisting user state.

## Key Data Flows

**Starting the VM:** Flutter `startVm()` → MethodChannel → `VmManager.startVm()` on executor → decompress `base.qcow2.gz` (first run), create `user.qcow2` overlay, build QEMU command with vCPU/RAM from `SharedPreferences`, spawn `ProcessBuilder`, start `VmService`. Then `VmState` polls SSH every 5s; status transitions `stopped → booting → running`.

**Terminal connection:** `TerminalScreen` detects `running`, opens `dartssh2` session to `127.0.0.1:2222` (root/alpine), allocates a PTY, renders via `xterm`. Up to 5 concurrent tabs; reconnects with exponential backoff (24 retries ≈ 2 min).

**Settings flow:** vCPU/RAM/disk stored as Flutter `SharedPreferences`, read by Kotlin in `VmManager.startVm()` before building the QEMU command. Changes only take effect on next VM start.

## Important File Locations

| Purpose | Path |
|---------|------|
| VM lifecycle core | `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` |
| Platform channel bridge | `lib/services/vm_platform.dart` |
| Multi-tab terminal | `lib/screens/terminal_screen.dart` |
| App root + navigation | `lib/main.dart` |
| QEMU + Alpine assets | `android/app/src/main/assets/vm/` |
| APK build script | `scripts/build_apk.sh` |
| Alpine image builder | `scripts/build_qcow2.sh` |
| Rootfs bootstrap | `scripts/_build_rootfs.sh` |

## Android Configuration
- `minSdk 26` (Android 8.0+), `compileSdk 35`
- Permissions: `INTERNET`, `FOREGROUND_SERVICE`, `WAKE_LOCK`
- ABI: `arm64-v8a` only (QEMU binaries are aarch64)

## Known Constraints
- QEMU runs TCG (software emulation), so CPU throughput is ~3× slower than native — avoid compute-intensive workloads in the VM
- QEMU stdout/stderr must be drained on a daemon thread to prevent pipe buffer deadlock (already handled in `VmManager`)
- `resetStorage` deletes `user.qcow2` only; `base.qcow2` is never modified at runtime
- SSH credentials are hardcoded: `root` / `alpine` (set by `assets/bootstrap/init_bootstrap.sh` at first boot)
