# Git & GitHub Issue Analysis Report

This report provides a comprehensive overview of the outstanding **Git branches** in the local repository and the current **open issues** fetched from the public GitHub repository at [AI2TH/Linxr/issues](https://github.com/AI2TH/Linxr/issues).

---

## Part 1: Git Branches Status

There are 5 remote branches with modifications that are not yet merged into the current working branch `Phase1`.

| Remote Branch | Main Commit | Description | Merge Compatibility |
| :--- | :--- | :--- | :--- |
| `origin/jules-15660002688726275069-e32c2741` | `e53b5eb` | **Security Fix**: Binds QEMU hostfwd explicitly to `127.0.0.1:2222` instead of `::2222`. Prevents other devices on the same network from connecting to the guest VM. | **Clean (No conflicts)** |
| `origin/perf-vm-status-isalive-check-11082778812970397128` | `1e86c99` | **Performance Fix**: Replaces slow exception-based control flow (`exitValue()`) in `getStatus()` with `Process.isAlive()`. Avoids throwing and catching exceptions on every 5s polling event. | **Clean (No conflicts)** |
| `origin/test-vm-start-success-path-12381125160299849839` | `688ea5a` | **Testing**: Adds a unit test suite for the `startVm` success path in `VmState` using mock platform MethodChannels. | **Clean (No conflicts)** |
| `origin/cleanup-qemu-cmd-builder-1062933609605046868` | `1854343` | **Refactoring**: Simplifies `buildQemuCommand` in [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt) using Kotlin's `buildList` DSL. | **Conflicts** (with subsequent QEMU options added in `Phase1`) |
| `origin/security-fix-hardcoded-ssh-password-8588595768819183751` | `5cd2dd7` | **Security / UI**: Introduces user-manageable SSH credentials and password-change dialog. | **Conflicts** (due to significant UI updates in `Phase1` terminal/about screens) |

---

## Part 2: GitHub Issues Analysis

We fetched the latest open issues from [AI2TH/Linxr/issues](https://github.com/AI2TH/Linxr/issues). Below is the technical breakdown and recommended responses for each issue.

### 1. Issue #19: Network Issue (reported by `jimkardy`)
* **Problem**: Running `npm install` inside the VM fails halfway due to a "weird network failure" (network drop/timeout) despite a strong host Wi-Fi connection.
* **Root Cause & Technical Context**:
  * QEMU user-mode networking (SLIRP) has known limitations under heavy network concurrency (which `npm install` triggers by firing dozens of parallel TCP sockets to fetch registry tarballs).
  * MUSL libc's DNS resolver (default in Alpine) does not handle parallel requests and fallback as gracefully as glibc, which can lead to transient DNS resolution failures under high CPU stress.
  * Since CPU throughput under QEMU software emulation (TCG) is ~3x slower, the emulator spends heavy cycles unpacking packages while network requests timeout.
* **Recommended Response / Solutions**:
  1. Recommend users switch to more resource-efficient package managers inside the VM, such as `pnpm` or `yarn`, which optimize registry requests and use fewer concurrent connections.
  2. Increase npm's network timeout limit by running:
     ```bash
     npm config set fetch-retry-maxtimeout 120000
     npm config set fetch-retry-mintimeout 20000
     ```
  3. Verify DNS config inside the guest's `/etc/resolv.conf` (e.g., using `nameserver 8.8.8.8` instead of SLIRP's default `10.0.2.3`).

---

### 2. Issue #18: Kernel Update Issue (reported by `fmohican`)
* **Problem**: The guest Alpine VM works fine, but the user cannot upgrade the kernel to a newer version; it remains stuck on `6.6.140`.
* **Root Cause & Technical Context**:
  * In [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L194-L203), QEMU is launched with explicit host-side kernel (`-kernel vmlinuz-virt`) and initrd (`-initrd initramfs-virt`) options:
    ```kotlin
    cmd += listOf("-kernel", kernel.absolutePath)
    cmd += listOf("-initrd", initrd.absolutePath)
    ```
  * These files are bundled as static assets inside the Android APK (in `assets/vm/`) and extracted to the device's storage at first launch.
  * Running `apk upgrade` inside Alpine Linux updates packages on the disk overlay (`user.qcow2`), but it does not affect the external boot files read by QEMU. QEMU completely bypasses the VM's internal `/boot` directory.
* **Recommended Response / Solutions**:
  * Explain to the user that the kernel is bundled at compile-time with the Android APK assets.
  * To upgrade the kernel, the project maintainer must update the kernel files in the source tree (using `scripts/build_qcow2.sh` to generate the new files) and rebuild/re-release the Android app APK.

---

### 3. Issue #17: Future idea - VNC / Graphical Support & GPU Acceleration (reported by `Alex-kiman`)
* **Problem**: The user wants graphical output support (VNC) and GPU acceleration (such as Vulkan, Virgil, OpenGL) to run graphical tools.
* **Root Cause & Technical Context**:
  * Currently, QEMU is launched with `-display none -serial stdio` in [VmManager.kt](file:///C:/Users/kevin/OneDrive/Documents/kalvin/Linxr/android/app/src/main/kotlin/com/ai2th/linxr/VmManager.kt#L191-L192), mapping only a serial console.
  * **VNC**: It is possible to configure QEMU with a VNC display card (e.g., `-display vnc=127.0.0.1:0`), but the app would need an integrated VNC client library in Flutter/Kotlin to render it, or the user would have to use an external Android VNC app connected to localhost.
  * **GPU Acceleration**: Supporting hardware-accelerated GPU graphics (VirGL with OpenGL/Vulkan) is extremely challenging because `libqemu.so` runs inside a sandboxed Android SELinux environment without direct bindings to host EGL/Vulkan drivers or a local display server (like X11/Wayland). Software rendering is possible but offers poor performance (~5-15 FPS).
* **Recommended Response / Solutions**:
  * Suggest running a headless VNC/X11 server inside Alpine Linux itself (e.g. `tigervnc` or `x11vnc` + a lightweight window manager) and exposing the port. The user can then connect using an external Android VNC Viewer app (e.g., RealVNC, bVNC) connecting to `localhost:5900` (which can be forwarded).
  * Acknowledge that native Virgil/GPU hardware acceleration inside the app wrapper is a complex long-term task due to Android driver/SELinux sandbox limitations.
