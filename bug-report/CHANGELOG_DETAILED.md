# Linxr Changelog — Detailed

This document tracks every line change made while fixing the 35 bugs from `BUGFIX_REPORT.md`. Each entry records the original code, the fixed code, and the root-cause analysis for the fix. This enables full auditability and reproducibility of all bug fixes applied across the project.

## Entry Format

Every changelog entry follows this structure:

### Issue ID

the C# / M# / L# / NEW-N identifier from BUGFIX_REPORT.md

**Files**

list of files modified with line ranges

**Before**

original code snippet (verbatim, with line numbers)

**After**

fixed code snippet (verbatim, with line numbers)

**Why broken**

root cause: what was wrong with the original code, with concrete failure scenario

**Why fixed**

correctness argument: why the new code resolves the root cause and how to verify

## Entry Template

```markdown
### Issue ID

[Issue identifier, e.g., C1, M2, L3, NEW-1]

**Files**

- `path/to/file.cs` — lines XX-YY
- `path/to/otherfile.kt` — lines AA-BB

**Before**

```csharp
// Line XX: [original code]
// Line XY: [original code]
```

**After**

```csharp
// Line XX: [fixed code]
// Line XY: [fixed code]
```

**Why broken**

[Root cause explanation with concrete failure scenario]

**Why fixed**

[Correctness argument explaining why the new code resolves the root cause and how to verify]
```

## Entries

<!-- Entries will be appended below as fixes land in steps 2-4 -->
### C1

**Files**

- `lib/screens/terminal_screen.dart` — lines 278, 282, 286

**Before**

```dart
// Line 278: tab.session!.stdout.listen(
//   (data) => tab.terminal.write(String.fromCharCodes(data)),
// Line 282: tab.session!.stderr.listen(
//   (data) => tab.terminal.write(String.fromCharCodes(data)),
// Line 286: tab.session?.stdin.add(Uint8List.fromList(data.codeUnits));
```

**After**

```dart
// Line 278: tab.session!.stdout.listen(
//   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 282: tab.session!.stderr.listen(
//   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 286: tab.session?.stdin.add(Uint8List.fromList(utf8.encode(data)));
```

**Why broken**

`String.fromCharCodes(byteList)` interprets each byte as a UTF-16 code unit, not a UTF-8 byte. Multi-byte UTF-8 sequences (Chinese characters, emoji, accented chars) have bytes >127 that map to wrong Unicode code points, rendering as garbage (e.g. `ä¸­æ–‡`). `data.codeUnits` returns UTF-16 code units, so typing non-ASCII text sends UTF-16 data to the SSH channel instead of UTF-8 bytes, silently corrupting input on the server.

**Why fixed**

`utf8.decode(bytes, allowMalformed: true)` correctly interprets a byte sequence as UTF-8 (the SSH protocol's wire format). `utf8.encode(string)` converts a Dart String back to proper UTF-8 bytes for transmission over SSH stdin. `allowMalformed: true` prevents `FormatException` on invalid sequences, keeping the terminal rendering.

Commit: `900ff78`

---

### C2

**Files**

- `lib/screens/terminal_screen.dart` — `_reconnect()` around line 344

**Before**

```dart
// Line 343: tab.session = null;
// Line 344: tab.client = null;
// Line 345: tab.terminal.write('\r\n--- Reconnecting ---\r\n');
// Line 346: _connect(tab);
```

**After**

```dart
// Line 343: tab.session = null;
// Line 344: tab.client = null;
// Line 345: tab.connState = _ConnState.idle;
// Line 346: tab.terminal.write('\r\n--- Reconnecting ---\r\n');
// Line 347: _connect(tab);
```

**Why broken**

`_connect(tab)` has a guard: `if (tab.connState == connecting || connected) return;`. `_reconnect()` nulled session and client but left `connState` as `connected`. Calling `_connect(tab)` hits the guard and returns immediately — reconnect is silently skipped, terminal shows "Disconnected" forever.

**Why fixed**

Setting `tab.connState = _ConnState.idle` before calling `_connect(tab)` lets the guard pass, allowing `_connect` to establish a fresh SSH session. `idle` is the correct starting state for a connection attempt.

Commit: `c2aa204`

---

### C3

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — line 150

**Before**

```kotlin
// Line 150: fun getStatus(): String {
```

**After**

```kotlin
// Line 150: @Synchronized
// Line 151: fun getStatus(): String {
```

**Why broken**

`getStatus()` reads/writes `vmProcess` and `isRunning` without synchronization while `startVm()` (line 40) and `stopVm()` (line 118) use `@Synchronized`. Flutter's `VmState` polls `getStatus()` every 5 seconds from the platform thread concurrently with `startVm()`/`stopVm()` on the executor thread — a TOCTOU data race. Can null out `vmProcess` mid-use, return stale `isRunning`, or NPE.

**Why fixed**

`@Synchronized` uses the same intrinsic monitor as `startVm()`/`stopVm()`, serializing all access to `vmProcess` and `isRunning` through one lock. All VM state mutations and reads now happen in a mutually exclusive critical section, eliminating the race.

Commit: `4e16403`

---

### C4

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — `createUserImage()` around lines 317–324

**Before**

```kotlin
// Line 317: }.start()
// Line 318: val exitCode = proc.waitFor()
// Line 319: if (exitCode != 0) {
// Line 320:     val err = proc.errorStream.bufferedReader().readText()
// Line 321:     throw RuntimeException("qemu-img create failed (exit $exitCode): $err")
// Line 322: }
```

**After**

```kotlin
// Line 317: }.start()
// Line 318: // Drain stderr on a background thread before waitFor() to prevent deadlock.
// Line 319: val stderrBuffer = StringBuilder()
// Line 320: val drainer = Thread {
// Line 321:     try { stderrBuffer.append(proc.errorStream.bufferedReader().readText()) }
// Line 322:     catch (_: Exception) { }
// Line 323: }.apply { start() }
// Line 324: val exitCode = proc.waitFor()
// Line 325: drainer.join(5000)
// Line 326: if (exitCode != 0) {
// Line 327:     throw RuntimeException("qemu-img create failed (exit $exitCode): $stderrBuffer")
// Line 328: }
```

**Why broken**

`proc.waitFor()` blocks until the subprocess exits. A Linux pipe has a ~64 KB buffer. If `qemu-img create` writes >64 KB to stderr (long error messages, debug output), the pipe fills and the process deadlocks on its next stderr write. `waitFor()` never returns because stderr is never read (it is only read after `waitFor()` returns).

**Why fixed**

Draining stderr on a concurrent background thread before `waitFor()` keeps the pipe buffer empty, allowing `qemu-img` to write arbitrarily large amounts to stderr without blocking. `drainer.join(5000)` waits up to 5 seconds for the drainer to complete, ensuring error output is available if the process fails.

Commit: `f2c636c`

---

### C5

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — `killOrphanQemu()` around lines 137–148

**Before**

```kotlin
// Line 141: if (pid == null) return
// Line 142: try {
// Line 143:     android.os.Process.killProcess(pid)
// Line 144:     Log.d(TAG, "Killed orphan QEMU PID $pid")
// Line 145:     Thread.sleep(500)
// Line 146: } catch (e: Exception) {
// Line 147:     Log.w(TAG, "killOrphan: ${e.message}")
// Line 148: }
```

**After**

```kotlin
// Line 141: if (pid == null) return
// Line 142: // Verify PID still belongs to QEMU before killing — PIDs are recycled on Android.
// Line 143: val cmdlineFile = File("/proc/$pid/cmdline")
// Line 144: if (!cmdlineFile.exists()) return
// Line 145: val cmdline = cmdlineFile.readText().replace('\u0000', ' ')
// Line 146: if (!cmdline.contains("qemu", ignoreCase = true)) {
// Line 147:     Log.w(TAG, "PID $pid is not QEMU (cmdline: $cmdline) — skipping kill")
// Line 148:     return
// Line 149: }
// Line 150: try {
// Line 151:     android.os.Process.killProcess(pid)
// Line 152:     Log.d(TAG, "Killed orphan QEMU PID $pid")
// Line 153:     Thread.sleep(500)
// Line 154: } catch (e: Exception) {
// Line 155:     Log.w(TAG, "killOrphan: ${e.message}")
// Line 156: }
```

**Why broken**

Linux PIDs are recycled. On Android where PID churn is high, if QEMU exits and its PID is reassigned to another process (a system service, another app, or even the app's own process), `android.os.Process.killProcess(pid)` sends SIGKILL to the wrong process — potentially the app's launcher, a system service, or another application.

**Why fixed**

Reading `/proc/$pid/cmdline` and verifying it contains `"qemu"` before killing confirms the PID still belongs to QEMU. If verification fails, the kill is skipped and a warning is logged with the actual cmdline contents. PID reuse attack is prevented.

Commit: `efcf2d9`

---

### C6

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt` — `onDestroy()` line 78, plus all `runOnUiThread` callbacks

**Before**

```kotlin
// Line 78: override fun onDestroy() {
// Line 79:     executor.shutdown()
// Line 80:     super.onDestroy()
// Line 81: }
```

And all `runOnUiThread { result.success(null) }` / `runOnUiThread { result.error(...) }` in `startVm`, `stopVm`, and `resetStorage` were unguarded.

**After**

```kotlin
// Line 78: override fun onDestroy() {
// Line 79:     executor.shutdownNow()
// Line 80:     executor.awaitTermination(10, TimeUnit.SECONDS)
// Line 81:     super.onDestroy()
// Line 82: }
```

All `runOnUiThread` callbacks now guarded with `if (!isFinishing) runOnUiThread { ... }`.

**Why broken**

`executor.shutdown()` only requests orderly shutdown — it does not wait for in-flight tasks. If `startVm`/`stopVm`/`resetStorage` is mid-execution on the executor when `onDestroy()` fires, the `result.success()`/`result.error()` callback fires after the Activity is destroyed. `runOnUiThread()` on a destroyed Activity throws `IllegalStateException` (Flutter engine detached), and the MethodChannel sees "reply already submitted".

**Why fixed**

`shutdownNow()` interrupts running tasks. `awaitTermination(10, TimeUnit.SECONDS)` blocks `onDestroy()` until tasks complete or the 10-second timeout expires, preventing late callbacks. The `if (!isFinishing)` guard provides an additional safety net for the narrow race where a callback fires after `onDestroy` begins but before `awaitTermination` returns.

Commit: `5e37d53`

---

### C7

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — `getFlutterInt()` lines 402–407

**Before**

```kotlin
// Line 402: private fun getFlutterInt(key: String, default: Int): Int {
// Line 403:     return try {
// Line 404:         flutterPrefs.getInt(key, default)
// Line 405:     } catch (_: ClassCastException) {
// Line 406:         flutterPrefs.getLong(key, default.toLong()).toInt()
// Line 407:     }
// Line 408: }
```

**After**

```kotlin
// Line 402: private fun getFlutterInt(key: String, default: Int): Int {
// Line 403:     // Read as String to handle all storage formats used by Flutter's
// Line 404:     // shared_preferences plugin across versions (Long, Int, or String).
// Line 405:     return flutterPrefs.getString(key, null)?.toIntOrNull() ?: default
// Line 406: }
```

**Why broken**

Flutter's `shared_preferences` plugin stores keys with a `flutter.` prefix and may use `Long`, `Int`, or `String` depending on plugin version. Newer plugin versions (2.x) store numeric values as `String`. The `getInt()`-with-`ClassCastException`-fallback-to-`getLong()` pattern misses the `String` case — `ClassCastException` is thrown and silently caught, falling back to the default value. User-configured vCPU, RAM, and disk values are completely ignored.

**Why fixed**

`getString()` returns the value regardless of whether it was stored as `Long`, `Int`, or `String` (all numeric types are serialized to their decimal string form). `toIntOrNull()` parses the string back to an `Int`. `?: default` handles any parsing failure safely. All three storage formats are handled uniformly without exceptions.

Commit: `8eaa466`

---

### C8

**Files**

- `scripts/build_apk.sh` — line 117

**Before**

```bash
# Line 117: flutter build apk --"${BUILD_TYPE}" 2>&1 || true
```

**After**

```bash
# Line 117: flutter build apk --"${BUILD_TYPE}" 2>&1
```

**Why broken**

`|| true` discards any non-zero exit code. A failed `flutter build apk` (Dart compile error, missing asset, plugin incompatibility) exits non-zero but the script continues to Step 5 ("Copy APK to output"), which fails with "APK not found". The real build error is hidden above the `|| true`, making it hard to diagnose build failures.

**Why fixed**

Removing `|| true` causes the script to exit with the actual `flutter build` exit code on failure. The `flutter build` error message is immediately visible in the output, making it clear what went wrong (Dart compilation issue, dependency problem, resource issue).

Commit: `866723e`
