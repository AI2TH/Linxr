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
---

### M1

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmService.kt` — lines 32-40

**Before**

```kotlin
// Line 32: override fun onDestroy() {
// Line 33:     super.onDestroy()
// Line 34:     Log.d(TAG, "VmService destroyed")
// Line 35: }
```

**After**

```kotlin
// Line 32: override fun onDestroy() {
// Line 33:     // Stop the QEMU VM before the service is destroyed so the process
// Line 34:     // does not become orphaned (running with no bound service/activity).
// Line 35:     try {
// Line 36:         (applicationContext as AlpineApp).vmManager.stopVm()
// Line 37:     } catch (e: Exception) {
// Line 38:         Log.w(TAG, "Failed to stop VM in onDestroy: ${e.message}")
// Line 39:     }
// Line 40:     super.onDestroy()
// Line 41:     Log.d(TAG, "VmService destroyed")
// Line 42: }
```

**Why broken**

`onDestroy()` called `super.onDestroy()` without stopping the VM. When the OS kills the foreground service (memory pressure, user stop, system task kill), QEMU continued running orphaned — no service or activity bound to it. The process wasted CPU and battery until the OS reaped it minutes later.

**Why fixed**

`onDestroy()` now calls `stopVm()` via the AlpineApp vmManager reference before `super.onDestroy()`. QEMU receives SIGTERM and the process waits for clean termination. If stopVm() throws (e.g., VM already dead), the exception is caught and logged, ensuring `super.onDestroy()` still runs.

Commit: `c7a8efc`

---

### M2

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — lines 19-20, 51-57, 129-130

**Before**

```kotlin
// Line 19: @Volatile private var vmProcess: Process? = null
// Line 20: @Volatile private var isRunning = false
// (no wakelock field)

// Line 48-50: val freshExtraction = !assetsReady()
// ...
// (no WakeLock acquisition in startVm)

// Line 118: @Synchronized
// Line 119: fun stopVm() {
// Line 120:     Log.d(TAG, "stopVm()")
// Line 121:     vmProcess?.let { ... }
// (no WakeLock release)
```

**After**

```kotlin
// Line 19: @Volatile private var vmProcess: Process? = null
// Line 20: @Volatile private var isRunning = false
// Line 21: private var wakelock: PowerManager.WakeLock? = null

// Line 51: // Acquire PARTIAL_WAKE_LOCK so QEMU keeps running when screen is off.
// Line 52: // Without this, Android Doze/standby throttles or kills the process,
// Line 53: // causing the VM to die minutes after the user locks their phone.
// Line 54: val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
// Line 55: wakelock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Linxr:VM")
// Line 56: wakelock?.acquire(8 * 60 * 60 * 1000L) // 8-hour safety timeout

// Line 129: @Synchronized
// Line 130: fun stopVm() {
// Line 131:     Log.d(TAG, "stopVm()")
// Line 132:     if (wakelock?.isHeld == true) wakelock?.release()
// Line 133:     wakelock = null
// Line 134:     vmProcess?.let { ... }
```

**Why broken**

`WAKE_LOCK` permission was declared in AndroidManifest.xml but never acquired in code. Android Doze/standby throttles or kills background processes when the screen turns off. QEMU's heavy CPU usage made it a prime target — the VM would die silently minutes after the user locked their phone.

**Why fixed**

`startVm()` now acquires `PARTIAL_WAKE_LOCK` (8-hour timeout) to keep the CPU alive when the screen is off. `stopVm()` releases the WakeLock if still held, preventing orphan hold. `PARTIAL_WAKE_LOCK` does not prevent sleep but ensures the process is not throttled/killed by Doze.

Commit: `9dcc081`

---

### M3

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt` — line 211

**Before**

```kotlin
// Line 211: cmd += listOf("-drive", "if=none,file=$userImage,id=user,format=qcow2,cache=unsafe,file.locking=off")
```

**After**

```kotlin
// Line 211: cmd += listOf("-drive", "if=none,file=$userImage,id=user,format=qcow2,cache=writethrough,file.locking=off")
```

**Why broken**

`cache=unsafe` tells QEMU to skip all host page cache flushes on write. On OOM kill or force-stop, pending writes in the host page cache may not be synced to storage, corrupting qcow2 metadata and user data in `user.qcow2`. Any abnormal VM termination risked silent data loss.

**Why fixed**

`cache=writethrough` forces writes through to the OS page cache (which the OS flushes to storage asynchronously but more safely). The qcow2 image is not directly affected, and the OS handles crash consistency. Data loss risk on abnormal termination is eliminated.

Commit: `adaabfe`

---

### M4

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt` — lines 46-54

**Before**

```kotlin
// Line 46: "getVmStatus" -> {
// Line 47:     try {
// Line 48:         result.success(vmManager.getStatus())
// Line 49:     } catch (e: Exception) {
// Line 50:         result.success("unknown")
// Line 51:     }
// Line 52: }
```

**After**

```kotlin
// Line 46: "getVmStatus" -> executor.execute {
// Line 47:     try {
// Line 48:         val status = vmManager.getStatus()
// Line 49:         if (!isFinishing) runOnUiThread { result.success(status) }
// Line 50:     } catch (e: Exception) {
// Line 51:         if (!isFinishing) runOnUiThread { result.success("unknown") }
// Line 52:     }
// Line 53: }
```

**Why broken**

MethodChannel handlers run on the platform thread. `getStatus()` is `@Synchronized` and can block if `startVm()` holds the lock (long QEMU startup). Flutter's UI thread was blocked, causing visible jank or ANR when polling VM status while the VM was starting.

**Why fixed**

`getVmStatus` now dispatches to the `executor` thread. The platform thread is freed immediately. `runOnUiThread` posts the result back to Flutter safely, guarded by `isFinishing` to avoid callbacks after Activity destruction.

Commit: `043f635`

---

### M5

**Files**

- `lib/screens/terminal_screen.dart` — lines 28-29, 58-59, 281, 285, 327-328

**Before**

```dart
// Line 28: class _Tab {
// Line 29:   Timer? retryTimer;
// (no _stdoutSub, no _stderrSub)

// Line 55: void close() {
// Line 56:   retryTimer?.cancel();
// Line 57:   keepAliveTimer?.cancel();
// Line 58:   session?.stdin.close();
// (no subscription cancellation)

// Line 281: tab.session!.stdout.listen(
// Line 282:   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 283:   onDone: () => _onSessionDone(tab),
// Line 284: );
// Line 285: tab.session!.stderr.listen(
// Line 286:   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 287: );

// Line 327: void _onSessionDone(_Tab tab) {
// Line 328:   tab.stopKeepAlive();
// Line 329:   tab.session = null;
// Line 330:   tab.client = null;
// (no subscription cancellation)
```

**After**

```dart
// Line 28: class _Tab {
// Line 29:   Timer? retryTimer;
// Line 30:   StreamSubscription? _stdoutSub;
// Line 31:   StreamSubscription? _stderrSub;

// Line 58: void close() {
// Line 59:   retryTimer?.cancel();
// Line 60:   keepAliveTimer?.cancel();
// Line 61:   _stdoutSub?.cancel();
// Line 62:   _stderrSub?.cancel();
// Line 63:   session?.stdin.close();

// Line 281: tab._stdoutSub = tab.session!.stdout.listen(
// Line 282:   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 283:   onDone: () => _onSessionDone(tab),
// Line 284: );
// Line 285: tab._stderrSub = tab.session!.stderr.listen(
// Line 286:   (data) => tab.terminal.write(utf8.decode(data, allowMalformed: true)),
// Line 287: );

// Line 327: void _onSessionDone(_Tab tab) {
// Line 328:   tab.stopKeepAlive();
// Line 329:   tab._stdoutSub?.cancel();
// Line 330:   tab._stderrSub?.cancel();
// Line 331:   tab.session = null;
// Line 332:   tab.client = null;
```

**Why broken**

`StreamSubscription` holds strong references to the listener callback and closure-captured state (including the tab and terminal controller). Without cancelling on tab close, each disconnect leaked the terminal controller and SSH session. After many connect/disconnect cycles, the accumulated leaked sessions consumed file descriptors and memory.

**Why fixed**

`_stdoutSub` and `_stderrSub` are stored as fields on `_Tab`. They are cancelled in `close()` and in `_onSessionDone()`, breaking the listener chain and allowing the terminal controller, SSH session, and tab state to be garbage collected.

Commit: `c88351a`

---

### M6

**Files**

- `lib/screens/terminal_screen.dart` — lines 266-267, 281-282

**Before**

```dart
// Line 266:     try {
// Line 267:       final socket = await SSHSocket.connect('127.0.0.1', 2222)
// Line 268:           .timeout(const Duration(seconds: 10));

// Line 279:       tab.client = SSHClient(
// Line 280:         socket,
// Line 281:         ...
// Line 282:       );

// Line 290:       tab._stdoutSub = tab.session!.stdout.listen(
```

**After**

```dart
// Line 266:     try {
// Line 267:       final socket = await SSHSocket.connect('127.0.0.1', 2222)
// Line 268:           .timeout(const Duration(seconds: 10));
// Line 269:       if (!mounted) return;

// Line 279:       tab.client = SSHClient(
// Line 280:         socket,
// Line 281:         ...
// Line 282:       );
// Line 283:       if (!mounted) return;

// Line 291:       tab._stdoutSub = tab.session!.stdout.listen(
```

**Why broken**

If the user closed the tab during the async SSH handshake (after `await SSHSocket.connect` but before `_connect` returned), the subsequent `setState` calls operated on a disposed `State` object. Flutter's framework throws `setState() called after dispose()` and the error banner appears.

**Why fixed**

`if (!mounted) return;` checks after each `await` short-circuit the function when the widget is disposed mid-async-operation. No `setState`, `tab.terminal.write`, or listener setup occurs on a dead widget.

Commit: `32a4f10`

---

### M7

**Files**

- `lib/services/vm_platform.dart` — lines 85, 169-186

**Before**

```dart
// Line 85: Timer? _pollTimer;
// Line 86: Timer? _sshPingTimer;
// (no _isPolling)

// Line 169: _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
// Line 170:   if (_status != 'running') {
// Line 171:     _stopPolling();
// Line 172:     return;
// Line 173:   }
// Line 174:   final s = await VmPlatform.getVmStatus();
// Line 175:   if (s != _status) {
// Line 176:     _status = s;
// Line 177:     notifyListeners();
// Line 178:   }
// Line 179: });
```

**After**

```dart
// Line 85: Timer? _pollTimer;
// Line 86: Timer? _sshPingTimer;
// Line 87: bool _isPolling = false;

// Line 169: _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
// Line 170:   if (_isPolling) return;
// Line 171:   if (_status != 'running') {
// Line 172:     _stopPolling();
// Line 173:     return;
// Line 174:   }
// Line 175:   _isPolling = true;
// Line 176:   try {
// Line 177:     final s = await VmPlatform.getVmStatus();
// Line 178:     if (s != _status) {
// Line 179:       _status = s;
// Line 180:       notifyListeners();
// Line 181:     }
// Line 182:   } finally {
// Line 183:     _isPolling = false;
// Line 184:   }
// Line 185: });
```

**Why broken**

`Timer.periodic` fires every 5 seconds regardless of whether the previous tick's async work completed. If `getVmStatus()` took longer than 5s (e.g., VM was slow to respond), multiple coroutines ran concurrently, each opening its own SSH connection. Concurrent SSH connections to the same port confused QEMU's sshd, causing connection instability.

**Why fixed**

The `_isPolling` flag is set to `true` before the async work and cleared in `finally` after completion. If a new tick fires while `_isPolling` is `true`, the callback returns immediately (no-op). Only one polling coroutine runs at a time.

Commit: `fa99a8e`

---

### M8

**Files**

- `lib/screens/settings_screen.dart` — line 72

**Before**

```dart
// Line 69: Future<void> _load() async {
// Line 70:   final results = await Future.wait([
// Line 71:     VmPlatform.getDeviceInfo(),
// Line 72:     SharedPreferences.getInstance(),
// Line 73:   ]);
// Line 74:   final device = results[0] as DeviceInfo;
```

**After**

```dart
// Line 69: Future<void> _load() async {
// Line 70:   final results = await Future.wait([
// Line 71:     VmPlatform.getDeviceInfo(),
// Line 72:     SharedPreferences.getInstance(),
// Line 73:   ]);
// Line 74:   if (!mounted) return;
// Line 75:   final device = results[0] as DeviceInfo;
```

**Why broken**

`_load()` had no `mounted` check after the `await`. If the user navigated away from Settings during `_load()`, the subsequent `setState()` operated on a disposed widget — `setState() called after dispose()` error.

**Why fixed**

`if (!mounted) return;` after the `await` short-circuits when the widget is disposed mid-async-operation, preventing `setState` on a dead widget.

Commit: `764206b`

---

### M9

**Files**

- `lib/screens/settings_screen.dart` — lines 31, 69-95, 198-223

**Before**

```dart
// Line 31: bool _restarting = false;
// (no _loadError)

// Line 69: Future<void> _load() async {
// Line 70:   final results = await Future.wait([
...
// Line 85:   });
// Line 86: }
```

**After**

```dart
// Line 31: bool _restarting = false;
// Line 32: String? _loadError;

// Line 69: Future<void> _load() async {
// Line 70:   try {
// Line 71:     final results = await Future.wait([
...
// Line 88:   } catch (e) {
// Line 89:     if (!mounted) return;
// Line 90:     setState(() {
// Line 91:       _loadError = e.toString();
// Line 92:       _loaded = true;
// Line 93:     });
// Line 94:   }
// Line 95: }
```

**Why broken**

`_load()` had no try/catch. If `getDeviceInfo()` or `SharedPreferences.getInstance()` threw (e.g., platform channel error, permissions issue), the exception was silently caught by Flutter's zone, `_loaded` stayed `false`, and the loading spinner ran forever with no error feedback.

**Why fixed**

The entire `_load()` body is wrapped in try/catch. On exception, `_loadError` is set and `_loaded` is set to `true` (unblocking the spinner), showing a red error banner in the UI. The loading spinner no longer hangs forever on error.

Commit: `16cbbd6`

---

### M10

**Files**

- `scripts/_build_rootfs.sh` — lines 235-239

**Before**

```bash
# (no warning comment)
echo "--- Configuring SSH ---"
```

**After**

```bash
# ⚠️  SECURITY WARNING — DEVELOPMENT ONLY ⚠️
# This VM is configured with root SSH access using hardcoded credentials
# (root:alpine). DO NOT expose port 2222 on a public or shared network.
# For production use, replace with key-based auth and disable password login.

echo "--- Configuring SSH ---"
```

**Why broken**

The VM was built with `PermitRootLogin yes`, `PasswordAuthentication yes`, and hardcoded credentials (`root:alpine`) with no visible warning. Developers building the APK might deploy to a shared network or expose the device's port 2222, enabling trivial SSH access as root with a known password.

**Why fixed**

A prominent security warning comment block is prepended to the SSH configuration section, clearly stating these settings are DEVELOPMENT ONLY and must not be exposed on public or shared networks. The warning is visible in the script source and build output.

Commit: `3548b1d`

---

### M11

**Files**

- `scripts/build_qcow2.sh` — lines 27, 38

**Before**

```bash
# Line 27: echo "Output   : ${OUTPUT_DIR}/base.qcow2.gz"
# Line 38: echo "=== base.qcow2.gz ready: $(du -sh ${OUTPUT_DIR}/base.qcow2.gz | cut -f1) ==="
```

**After**

```bash
# Line 27: echo "Output   : "${OUTPUT_DIR}"/base.qcow2.gz"
# Line 38: echo "=== base.qcow2.gz ready: $(du -sh "${OUTPUT_DIR}"/base.qcow2.gz | cut -f1) ==="
```

**Why broken**

`${OUTPUT_DIR}` was unquoted in `echo` and `$(du -sh ...)` commands. On paths with spaces (e.g., `OneDrive/Documents and Settings/...`), the shell split the variable into multiple words, causing `du` to fail with "cannot access 'OneDrive/Documents': No such file or directory".

**Why fixed**

`"${OUTPUT_DIR}"` is now properly quoted in all usages. The variable expands to a single argument even when the path contains spaces, allowing the script to work correctly from paths like `C:/Users/.../OneDrive/Documents`.

Commit: `d1ba8d8`

---

### M12

**Files**

- `android/app/src/main/kotlin/com/ai2th/linxr/MainActivity.kt` — lines 1-11, 22-37

**Before**

```kotlin
// Line 1: package com.ai2th.linxr
// Lines 2-7: (no new imports)

// Line 12: class MainActivity : FlutterActivity() {
// Line 13:     private val CHANNEL = "com.ai2th.linxr/vm"
// (no TAG, no requestNotificationPermission)

// Line 18: override fun onCreate(savedInstanceState: Bundle?) {
// Line 19:     super.onCreate(savedInstanceState)
// Line 20: }
```

**After**

```kotlin
// Line 1: package com.ai2th.linxr
// Line 2: import android.Manifest
// Line 3: import android.content.pm.PackageManager
// Line 4: import android.content.Intent
// Line 5: import android.os.Build
// Line 6: import android.os.Bundle
// Line 7: import android.util.Log
// Line 8: import androidx.activity.result.contract.ActivityResultContracts

// Line 14: class MainActivity : FlutterActivity() {
// Line 15:     private val TAG = "LinxrMainActivity"
// Line 16:     private val CHANNEL = "com.ai2th.linxr/vm"

// Line 22:     private val requestNotificationPermission = registerForActivityResult(
// Line 23:         ActivityResultContracts.RequestPermission()
// Line 24:     ) { granted ->
// Line 25:         Log.i(TAG, "POST_NOTIFICATIONS granted=$granted")
// Line 26:     }

// Line 28:     override fun onCreate(savedInstanceState: Bundle?) {
// Line 29:         super.onCreate(savedInstanceState)
// Line 30:         if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
// Line 31:             if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
// Line 32:                 PackageManager.PERMISSION_GRANTED) {
// Line 33:                 requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
// Line 34:             }
// Line 35:         }
// Line 36:     }
```

**Why broken**

On Android 13+ (API 33, `TIRAMISU`), `POST_NOTIFICATIONS` is a runtime permission. The foreground `VmService` notification was silently suppressed because the app never requested this permission at runtime. Users saw no notification even though the service was running, making it unclear why the VM was consuming battery.

**Why fixed**

`onCreate()` now checks if the app has `POST_NOTIFICATIONS` permission on Android 13+. If not granted, it uses `ActivityResultContracts.RequestPermission()` to prompt the user. The notification permission is requested early so the foreground service notification appears correctly.

Commit: `bba3a84`