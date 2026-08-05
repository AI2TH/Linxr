# Linxr — Implementation Review

> Full codebase audit covering Dart/Flutter, Kotlin/Android, and build infrastructure.
> Reviewed: 2026-06-25

---

## Executive Summary

| Severity | Count | Layers affected |
|----------|-------|-----------------|
| 🔴 Critical / High | **8** | Kotlin (5), Dart (3) |
| 🟡 Medium | **12** | Kotlin (5), Dart (5), Scripts (2) |
| 🟢 Low / Quality | **15** | All layers |
| **Total** | **35** | |

The project is well-architected and the CLAUDE.md documentation is accurate. However, there are **real bugs** that affect correctness (UTF-8 encoding in terminal, reconnect logic, thread safety) and **data integrity risks** (QEMU `cache=unsafe`, PID reuse kills).

---

## 🔴 Critical / High Severity

### 1. Terminal garbles multi-byte characters (UTF-8 bug)
**File:** [terminal_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart) — lines 278, 282, 286

**Incoming data** uses `String.fromCharCodes(data)` which interprets raw bytes as char codes, not UTF-8. Chinese characters, emoji, and accented characters will render as garbage.

**Outgoing data** uses `data.codeUnits` which sends UTF-16 code units instead of UTF-8 bytes. Non-ASCII user input is silently corrupted.

```diff
 // Line 278 — stdout
-tab.terminal.write(String.fromCharCodes(data));
+tab.terminal.write(utf8.decode(data, allowMalformed: true));

 // Line 282 — stderr
-tab.terminal.write(String.fromCharCodes(data));
+tab.terminal.write(utf8.decode(data, allowMalformed: true));

 // Line 286 — user input
-tab.session!.stdin.add(Uint8List.fromList(data.codeUnits));
+tab.session!.stdin.add(Uint8List.fromList(utf8.encode(data)));
```

> [!CAUTION]
> This bug means **any non-ASCII text in the terminal is broken** — file paths with special characters, language tools, etc. The `utf8` import already exists in the file (line 2) and is used correctly in `_paste()`, so this is an inconsistency.

---

### 2. Reconnect silently fails — never reconnects
**File:** [terminal_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart) — lines 335–346

`_reconnect()` nulls out `session` and `client` but **doesn't reset `connState` to `idle`**. Then it calls `_connect(tab)`, which has a guard: `if (tab.connState == connecting || connected) return;`. Since `connState` is still `connected`, the reconnect is silently skipped. The terminal shows "Disconnected" forever.

```diff
 void _reconnect(_Tab tab) {
   tab.session = null;
   tab.client = null;
+  tab.connState = _ConnState.idle;
   _connect(tab);
 }
```

---

### 3. `getStatus()` data race (Kotlin)
**File:** [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) — line ~150

`getStatus()` reads and mutates `vmProcess` and `isRunning` **without synchronization**, while `startVm()` and `stopVm()` are `@Synchronized`. Flutter polls `getStatus()` every 5 seconds from the platform thread while `startVm()` runs on the executor thread — a textbook data race that can null out `vmProcess` mid-use or read stale values.

**Fix:** Add `@Synchronized` to `getStatus()`, or use `AtomicReference`/`ReentrantLock`.

---

### 4. `createUserImage()` stderr deadlock risk (Kotlin)
**File:** [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) — line ~318

`proc.waitFor()` is called **before** reading `proc.errorStream`. If `qemu-img` writes more than ~64 KB to stderr, the pipe buffer fills and the process **deadlocks** — `waitFor()` never returns.

**Fix:** Drain stderr on a separate thread (or set `redirectErrorStream(true)`) before calling `waitFor()`.

---

### 5. `killOrphanQemu()` may kill wrong process (Kotlin)
**File:** [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) — line ~142

PIDs are recycled. If QEMU died and its PID was reused by another process, `android.os.Process.killProcess(pid)` kills the wrong process.

**Fix:** Verify `/proc/$pid/cmdline` contains `qemu` before killing.

---

### 6. `executor.shutdown()` without awaiting termination (Kotlin)
**File:** [MainActivity.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt) — line ~78

If `startVm` is still running when `onDestroy()` fires, the `result.success()` callback will invoke `runOnUiThread` on a destroyed Activity → crash or `IllegalStateException`.

**Fix:** `executor.shutdownNow()` + `awaitTermination()`, and guard `runOnUiThread` with `isDestroyed`.

---

### 7. SharedPreferences type mismatch (Kotlin ↔ Flutter)
**File:** [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) — line ~402

Flutter's `shared_preferences` plugin stores values with a `flutter.` prefix and may use `Long` (not `Int`) or even `String` depending on plugin version. The Kotlin code reads via `getInt()` with a `ClassCastException` fallback to `getLong`, but newer plugin versions may store as `String` — causing silent fallback to defaults, ignoring user-configured values.

---

### 8. Build failures silently swallowed
**File:** [build_apk.sh](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/scripts/build_apk.sh) — line ~117

```bash
flutter build apk --"${BUILD_TYPE}" 2>&1 || true
```

The `|| true` means a **failed APK build** is silently ignored. The script continues to "copy APK" and then fails with a confusing "APK not found" error, hiding the real build error.

---

## 🟡 Medium Severity

| # | File | Issue |
|---|------|-------|
| 9 | [VmService.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmService.kt) | `onDestroy()` doesn't call `stopVm()` — QEMU becomes orphaned, wastes CPU/battery |
| 10 | [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) | `WAKE_LOCK` permission declared but **never acquired** — VM gets throttled/killed when screen off |
| 11 | [VmManager.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) | `cache=unsafe` on user disk — crash/OOM kill = **data corruption** in `user.qcow2` |
| 12 | [MainActivity.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt) | `getVmStatus` and `getDeviceInfo` run on main/platform thread — can block UI |
| 13 | [terminal_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart) | stdout/stderr `StreamSubscription`s never stored or cancelled — memory leak |
| 14 | [terminal_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/terminal_screen.dart) | Tab can be closed during async `_connect()` → operations on disposed controller |
| 15 | [vm_platform.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/services/vm_platform.dart) | Async callbacks in `Timer.periodic` can overlap → multiple concurrent SSH connections |
| 16 | [settings_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/settings_screen.dart) | No `mounted` check in async `_load()` — `setState` on disposed widget throws |
| 17 | [settings_screen.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/screens/settings_screen.dart) | No error handling in `_load()` — failure = infinite loading spinner |
| 18 | [_build_rootfs.sh](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/scripts/_build_rootfs.sh) | `PermitRootLogin yes` + `PasswordAuthentication yes` + hardcoded `root:alpine` — exploitable if port exposed on shared network |
| 19 | [build_qcow2.sh](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/scripts/build_qcow2.sh) | Unquoted `${OUTPUT_DIR}` — breaks on paths with spaces (your path has spaces: `OneDrive/Documents`) |
| 20 | [MainActivity.kt](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt) | No `POST_NOTIFICATIONS` runtime permission request — foreground service notification silently suppressed on Android 13+ |

---

## 🟢 Low / Code Quality

| # | Scope | Issue |
|---|-------|-------|
| 21 | All Dart files | Hardcoded colors duplicated ~40+ times — should be theme constants |
| 22 | Multiple files | SSH credentials `root`/`alpine`/`2222` duplicated in 3+ files as magic values |
| 23 | All Dart files | Deprecated `Color.withOpacity()` — use `Color.withValues(alpha: ...)` |
| 24 | `terminal_screen.dart` | Keep-alive sends zero-length `Uint8List` — may not detect dead connections |
| 25 | `terminal_screen.dart` | `_onSessionDone` doesn't call `client.close()` before nulling — socket leak |
| 26 | `terminal_screen.dart` | CLAUDE.md says "exponential backoff" but code uses fixed 5s retry |
| 27 | `VmManager.kt` | `vmProcess!!` double-bang after null check — fragile |
| 28 | All Kotlin files | `TAG` as instance field — should be `companion object { const val }` |
| 29 | `VmManager.kt` | `extractAssets()` catches all exceptions silently |
| 30 | `pubspec.yaml` | `cupertino_icons` dependency is unused (only Material icons used) |
| 31 | `build.gradle` | `minifyEnabled false` / `shrinkResources false` in release — bloated APK |
| 32 | `build.gradle` | JSch `0.1.55` is outdated with known CVEs |
| 33 | `.gitignore` | `docker/` is gitignored — `Dockerfile.build` won't be tracked |
| 34 | Scripts | `build_apk.sh` and `build_aab.sh` share ~90% duplicated code |
| 35 | Scripts | Some scripts have `\r\n` line endings — will fail on Linux (`bad interpreter`) |

---

## Architecture Deviations from CLAUDE.md

| Claim in CLAUDE.md | Reality |
|---------------------|---------|
| "reconnects with exponential backoff (24 retries ≈ 2 min)" | Fixed 5-second delay, and reconnect is **broken** (issue #2) |
| VmState polls SSH every 5 seconds | Correct — `Timer.periodic(5s)` in [vm_platform.dart](file:///mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/lib/services/vm_platform.dart) |
| QEMU stdout/stderr "must be drained on a daemon thread (already handled)" | ✅ Handled for QEMU process; ❌ NOT handled for `qemu-img` subprocess (issue #4) |

---

## Recommended Fix Priority

> [!IMPORTANT]
> I'd suggest tackling these in this order — the first 4 are correctness bugs that directly affect users:

1. **UTF-8 encoding** (#1) — terminal is broken for non-ASCII text
2. **Reconnect logic** (#2) — terminal never auto-reconnects after disconnect
3. **`getStatus()` race** (#3) — can crash or show wrong VM status
4. **WakeLock** (#10) — VM gets killed when screen turns off
5. **`cache=unsafe`** (#11) — user data corruption on abnormal exit
6. **Build script `|| true`** (#8) — hides real build errors
7. Everything else

Would you like me to fix any of these?
