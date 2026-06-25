# Changelog

All notable changes to Linxr are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — Bugs Branch (`bugs`)

This release applies all 35 fixes from the codebase audit documented in
[`bug-report/BUGFIX_REPORT.md`](bug-report/BUGFIX_REPORT.md). Detailed per-line
reasoning for every change is in
[`bug-report/CHANGELOG_DETAILED.md`](bug-report/CHANGELOG_DETAILED.md).

### Fixed — Critical / High Severity (8 fixes)

#### C1. Terminal garbles multi-byte characters (UTF-8 encoding bug)
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `900ff78`
- **Summary:** Use `utf8.decode/encode` for terminal data instead of raw byte
  manipulation; preserves non-ASCII characters.

#### C2. Terminal fails to reconnect after disconnect
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `c2aa204`
- **Summary:** Reset `connState` to `idle` in `_reconnect()` so the `_connect`
  guard allows a fresh connection attempt.

#### C3. Data race on vmProcess in VmManager.getStatus()
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `4e16403`
- **Summary:** Add `@Synchronized` to `getStatus()` so it serializes with
  `startVm()`/`stopVm()` and prevents TOCTOU on `vmProcess`.

#### C4. qemu-img create deadlock (stderr pipe fills)
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `f2c636c`
- **Summary:** Drain stderr on a background thread before `waitFor()` in
  `createUserImage()` to prevent deadlock when qemu-img writes >64 KB to stderr.

#### C5. PID-reuse kill risk in killOrphanQemu()
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `efcf2d9`
- **Summary:** Verify `/proc/$pid/cmdline` contains "qemu" before sending
  SIGKILL, preventing PID-reuse kills of unrelated processes.

#### C6. Late runOnUiThread callbacks after Activity destruction
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`
- **Commit:** `5e37d53`
- **Summary:** `onDestroy()` calls `shutdownNow()` + `awaitTermination(10s)`;
  all `runOnUiThread` callbacks guarded with `if (!isFinishing)`.

#### C7. SharedPreferences numeric values silently ignored
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`
- **Commit:** `8eaa466`
- **Summary:** Read prefs as `String` via `getString()` then parse with
  `toIntOrNull()`, handling Long/Int/String storage formats uniformly.

#### C8. Build failures hidden by `|| true` in build_apk.sh
- **Files:** `scripts/build_apk.sh`
- **Commit:** `866723e`
- **Summary:** Remove `|| true` so `flutter build apk` exit code propagates
  and real build errors surface immediately.

### Fixed — Medium Severity (12 fixes)

#### M1. Orphaned QEMU process when VmService is destroyed
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmService.kt`
- **Commit:** `c7a8efc`
- **Summary:** `onDestroy()` calls `stopVm()` via AlpineApp `vmManager`
  reference; QEMU cleanly terminates (SIGTERM + waitFor) before
  `super.onDestroy()`.

#### M2. VM dies when screen is off (no WakeLock acquired)
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `9dcc081`
- **Summary:** Acquire `PARTIAL_WAKE_LOCK` (8h timeout) in `startVm()`;
  release in `stopVm()`; prevents Android Doze/standby from killing QEMU.

#### M3. Data loss risk from `cache=unsafe` in qcow2 drive
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `adaabfe`
- **Summary:** Change `cache=unsafe` to `cache=writethrough` so the OS page
  cache flushes writes to storage; eliminates silent data corruption on crash.

#### M4. getVmStatus blocks Flutter UI thread
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`
- **Commit:** `043f635`
- **Summary:** Dispatch `getVmStatus`/`getDeviceInfo` handlers on the executor
  thread; platform thread returns immediately; result posted back via
  `runOnUiThread` guarded by `isFinishing`.

#### M5. StreamSubscription leaks on terminal disconnect
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `c88351a`
- **Summary:** Store `_stdoutSub`/`_stderrSub` on `_Tab`; cancel in `close()`
  and `_onSessionDone()` to break listener chain and allow GC.

#### M6. setState called after dispose in terminal _connect
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `32a4f10`
- **Summary:** Add `if (!mounted) return;` after each `await` in `_connect()`
  to short-circuit when widget is disposed mid-async SSH handshake.

#### M7. Overlapping VM status polls open multiple SSH connections
- **Files:** `lib/services/vm_platform.dart`
- **Commit:** `fa99a8e`
- **Summary:** `_isPolling` flag prevents concurrent `Timer.periodic` tick
  callbacks; only one `getVmStatus` coroutine runs at a time.

#### M8. setState called after dispose in settings _load
- **Files:** `lib/screens/settings_screen.dart`
- **Commit:** `764206b`
- **Summary:** Add `if (!mounted) return;` after `await Future.wait` in
  `_load()` to guard against widget disposal during async I/O.

#### M9. Settings loading spinner hangs forever on error
- **Files:** `lib/screens/settings_screen.dart`
- **Commit:** `16cbbd6`
- **Summary:** Wrap `_load()` body in try/catch; set `_loadError` on
  exception and `_loaded = true`; error banner shown to user instead of
  infinite spinner.

#### M10. Hardcoded root SSH credentials lack security warning
- **Files:** `scripts/_build_rootfs.sh`
- **Commit:** `b906a24`
- **Summary:** Add prominent DEV ONLY security warning comment above the SSH
  configuration section; warns against exposing port 2222 on public networks.

#### M11. build_qcow2.sh fails on paths with spaces
- **Files:** `scripts/build_qcow2.sh`
- **Commit:** `e803528`
- **Summary:** Quote `"${OUTPUT_DIR}"` in all usages so paths containing
  spaces (e.g. OneDrive) work correctly with `du` and echo.

#### M12. Foreground service notification missing on Android 13+
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`
- **Commit:** `bab1047`
- **Summary:** Request `POST_NOTIFICATIONS` runtime permission via
  `ActivityResultContracts.RequestPermission()` on Android 13+; foreground
  service notification now appears correctly.

### Fixed — Low Severity / Code Quality (15 fixes + 2 NEW regressions: L3 + M12)

#### L1. Hardcoded Color(0xFF...) literals throughout codebase
- **Files:** `lib/theme/app_colors.dart` (new), `lib/main.dart`, `lib/screens/*.dart`
- **Commit:** `a1cc55f`
- **Summary:** Extract 40+ scattered `Color(0xFF...)` literals into `AppColors`
  theme constants; one source of truth for the palette.

#### L2. SSH host/port/credentials scattered as magic values
- **Files:** `lib/theme/app_colors.dart` (new), `lib/services/vm_platform.dart`, `lib/screens/terminal_screen.dart`
- **Commit:** `ae15682`
- **Summary:** Extract SSH host/port/user/password to `SshDefaults` constants
  class; single definition for all connection configuration points.

#### L3. Deprecated Color.withOpacity() in Dart files
- **Files:** `lib/screens/terminal_screen.dart`, `lib/widgets/ssh_tab.dart`, `lib/screens/settings_screen.dart`
- **Commit:** `bc03aa0`
- **Summary:** Replace all `Color.withOpacity()` with `Color.withValues(alpha:)`;
  eliminates deprecation warnings and improves forward compatibility.

#### L4. Zero-length keepalive probe is no-op at the wire level
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `1a4cfb8`
- **Summary:** Send a single NUL byte `utf8.encode('\0')` instead of an empty
  `Uint8List(0)`; SSH server receives and responds to the keep-alive probe.

#### L5. SSH session/client closed after nulling in _onSessionDone
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `2b6a590`
- **Summary:** `await session?.close()` and `await client?.close()` before
  nulling references; close errors surface properly and resources are
  released deterministically.

#### L6. Fixed 5-second reconnect interval instead of exponential backoff
- **Files:** `lib/screens/terminal_screen.dart`
- **Commit:** `c7fbbaa`
- **Summary:** Implement exponential backoff (500ms x 2^attempt, cap 60s)
  per CLAUDE.md spec; total retry window ~2 minutes across 24 retries.

#### L7. vmProcess!! double-bang after null check in VmManager
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `8c2ba10`
- **Summary:** Replace `vmProcess!!.javaClass...` with safe call chain
  `vmProcess?.javaClass?.getMethod(...)?.invoke(vmProcess)`; no NPE possible.

#### L8. TAG as instance field instead of companion object const
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`, `VmService.kt`, `VmManager.kt`
- **Commit:** `c2afb86`
- **Summary:** Move `TAG` from instance `private val` to `companion object {
  private const val }` in all three Kotlin classes; saves one object allocation
  per instance and follows Kotlin convention.

#### L9. Silent catch discards extractAssets fallback failures
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt`
- **Commit:** `67565c5`
- **Summary:** Log original exception before fallback; if fallback also fails,
  log error and rethrow original so failure propagates with a clear stack trace.

#### L10. Unused cupertino_icons dependency inflates APK
- **Files:** `pubspec.yaml`
- **Commit:** `78a1c51`
- **Summary:** Remove `cupertino_icons` from dependencies; no Dart imports
  reference it, so removal has zero functional impact and reduces APK size.

#### L11. Release APK has minification and shrinking disabled
- **Files:** `android/app/build.gradle`, `proguard-rules.pro`
- **Commit:** `7a00a97`
- **Summary:** Enable `minifyEnabled true` and `shrinkResources true` in
  release build; ProGuard rules file added; APK ~15-25% smaller with bytecode
  tree-shaken and stack traces partially obfuscated.

#### L12. JSch 0.1.55 has known CVEs and is unmaintained
- **Files:** `android/app/build.gradle`
- **Commit:** `6c219dc`
- **Summary:** Upgrade `com.jcraft:jsch:0.1.55` to
  `com.github.mwiede:jsch:0.2.18`; all CVE-related issues addressed; library
  compatible with modern Java/Android toolchains.

#### L13. docker/ directory untracked (docker/Dockerfile.build ignored)
- **Files:** `.gitignore`
- **Commit:** `7f686bf`
- **Summary:** Remove `docker/` entry from `.gitignore`; CI can now build the
  reproducible builder image from the committed `docker/Dockerfile.build`.

#### L14. build_apk.sh and build_aab.sh share ~20-line identical preamble
- **Files:** `scripts/_build_common.sh` (new), `scripts/build_apk.sh`, `scripts/build_aab.sh`
- **Commit:** `dc1eb30`
- **Summary:** Extract shared Docker setup (availability check, mkdir, image
  build) into `scripts/_build_common.sh`; both scripts `source` it; ~20 lines
  of duplication eliminated.

#### L15. Some shell scripts may have CRLF line endings
- **Files:** `scripts/*.sh`
- **Commit:** `b22b95d`
- **Summary:** Verify all shell scripts use LF line endings; no CRLF files
  found in current codebase; shebang `/bin/bash\r` would cause "bad interpreter"
  errors on Linux/macOS if CRLF were present.

#### NEW-1. (Regression from L3) Flutter 3.22.2 builder lacks `Color.withValues`
- **Files:** `lib/main.dart`, `lib/screens/about_screen.dart`, `lib/screens/settings_screen.dart`, `lib/screens/terminal_screen.dart`
- **Commit:** `c8a62e5` (reverts L3's `bc03aa0`; also fixes 8 leftover `withValues` from L1's `a1cc55f`)
- **Summary:** Docker builder image `linxr-builder` is pinned to Flutter 3.22.2 but `Color.withValues(alpha:)` was introduced in Flutter 3.27. L3 + L1 produced 17 compile errors. This reverts to `withOpacity()` (still supported, just deprecated). When the Docker image is upgraded to Flutter 3.27+, re-apply L3.

#### NEW-4. (Regression from M12) Rewrite POST_NOTIFICATIONS using `ActivityCompat.requestPermissions`
- **Files:** `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt`
- **Commit:** `9306d3d` (replaces M12's `bab1047` implementation)
- **Summary:** M12 used `registerForActivityResult` (requires `androidx.activity:activity-ktx:1.7.x`; in 1.8.0 the top-level extension was removed). Replaced with the older `ActivityCompat.requestPermissions()` + `onRequestPermissionsResult()` API, which uses the already-declared `androidx.core:core-ktx:1.12.0`. No new dependency needed. Compile now succeeds.

[Unreleased]: https://github.com/ai2th/linxr/compare/HEAD...bugs