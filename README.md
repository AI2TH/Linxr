# Linxr

**Bare Alpine Linux VM on Android — no root required.**

Linxr runs a full Alpine Linux environment inside a QEMU virtual machine on any Android device. Access it through the built-in SSH terminal or any external SSH client. No root, no container runtimes, no special hardware.

---

## Features

- **Full Linux shell** — Alpine Linux 3.19 with OpenRC init, OpenSSH, sudo, bash
- **Docker support** — full Docker Engine with overlay2 storage and bridge networking
- **Multi-tab terminal** — up to 5 concurrent SSH sessions with auto-reconnect and keepalive
- **External SSH access** — connect from any SSH client on the same device
- **No root required** — QEMU runs as a normal Android app process
- **Persistent storage** — a writable QCOW2 overlay preserves your changes across reboots
- **Dynamic resources** — configure vCPU count, RAM, and disk size from the Settings screen
- **Internet access** — SLIRP networking gives the VM full outbound internet via the host

---

## Screenshots

| Home — stopped | Home — running | Terminal |
|---|---|---|
| ![Home stopped](https://ai2th.github.io/screenshots/linxr/01-home-stopped.png) | ![Home running](https://ai2th.github.io/screenshots/linxr/02-home-running.png) | ![Terminal](https://ai2th.github.io/screenshots/linxr/05-terminal-keyboard.png) |

| About | License | Components |
|---|---|---|
| ![About](https://ai2th.github.io/screenshots/linxr/06-about.png) | ![License](https://ai2th.github.io/screenshots/linxr/07-about-license.png) | ![Components](https://ai2th.github.io/screenshots/linxr/08-about-components.png) |

---

## Requirements

| Requirement | Minimum |
|---|---|
| Android | 8.0 (API 26) |
| Architecture | arm64-v8a |
| Free storage | ~250 MB (APK + VM assets) |
| RAM | 2 GB device RAM recommended |

---

## Quick Start

1. Install the APK
2. Open **Linxr** → tap **Start VM**
3. Wait ~2–3 minutes for Alpine to boot (first run takes longer — assets are extracted on device)
4. Switch to the **Terminal** tab — it auto-connects once SSH is ready
5. Log in as `root` / `alpine`

### External SSH (optional)

```bash
ssh root@localhost -p 2222
# password: alpine
```

---

## Architecture

```
Android App (Flutter + Kotlin)
│
├── VmManager.kt          — asset extraction, QEMU lifecycle
├── VmService.kt          — foreground service keeps QEMU alive
│
├── QEMU (libqemu.so)     — aarch64 machine emulation
│   └── SLIRP networking  — NAT with hostfwd TCP:127.0.0.1:2222→:22
│
└── Alpine Linux VM
    ├── OpenRC init       — sysinit / boot / default runlevels
    ├── OpenSSH sshd      — listens on :22 inside the VM
    ├── Static IP         — 10.0.2.15/24, gw 10.0.2.2, DNS 10.0.2.3
    └── virtio-blk        — base.qcow2 (read-only) + user.qcow2 (writable)
```

### Disk layout

| File | Purpose |
|---|---|
| `base.qcow2` | Read-only Alpine rootfs (openssh, sudo, bash baked in) |
| `user.qcow2` | Writable overlay — your data lives here |
| `vmlinuz-virt` | Linux 6.6 kernel (virt profile) |
| `initramfs-virt` | Initial RAM filesystem |

### SLIRP port forwarding

| Host port | VM port | Protocol | Service |
|---|---|---|---|
| 2222 | 22 | TCP | SSH |

---

## Building from Source

### Prerequisites

- macOS or Linux with Docker (for QEMU binaries and qcow2 builder)
- Android SDK (API 31+)
- Flutter 3.x

### 1 — Build the Alpine base image

```bash
bash scripts/build_qcow2.sh
```

Outputs `android/app/src/main/assets/vm/base.qcow2.gz`.

### 2 — Build the APK

```bash
bash scripts/build_apk.sh debug     # debug build
bash scripts/build_apk.sh release   # release build (requires keystore)
```

Output: `build/linxr-debug.apk` or `build/linxr-release.apk`

### 2b — Build the AAB (Play Store)

```bash
bash scripts/build_aab.sh           # release AAB (default)
```

Output: `build/linxr-release.aab`

### 3 — Sideload

```bash
adb install build/linxr-debug.apk
```

---

## Default Credentials

| Field | Value |
|---|---|
| Username | `root` |
| Password | `alpine` |

> Change the root password with `passwd` after first login.

---

## VM Networking

The VM uses QEMU SLIRP (user-mode networking). Inside the VM:

```
eth0      10.0.2.15/24
gateway   10.0.2.2
DNS       10.0.2.3  (SLIRP built-in resolver)
```

Install packages normally:

```sh
apk add curl git python3
```

---

## Troubleshooting & FAQs

### Known Issues & Bug Tracker

| Issue ID | Category | Reported By | Date | Description & Root Cause |
| :--- | :--- | :--- | :--- | :--- |
| **#19** | Network Issue | jimkardy | Jun 9 | `npm install` fails midway with network errors despite strong WiFi. **Root cause:** SLIRP user-mode networking drops packets/DNS requests under high concurrency, worsened by TCG CPU overhead. |
| **#18** | Kernel Update Issue | fmohican | Jun 7 | Can't upgrade kernel past 6.6.140 via `apk upgrade`. **Root cause:** QEMU boots external kernel files bundled in the APK, not from the guest's `/boot`. |
| **#16** | Terminal Slowness | User | Jun 25 | Commands in terminal feel slow/delayed (even simple commands like `ls`). **Root cause:** CPU emulation (TCG) overhead and emulator translation (Berberis), not network/SLIRP. |

---

### 1. `npm install` fails or drops connection inside the VM (Issue #19)

Under heavy network operations (like `npm install`), the QEMU SLIRP (user-mode) network stack can drop packets or DNS queries due to high concurrency. Additionally, software CPU emulation (TCG) adds CPU latency which can cause connections to time out.

#### Detailed Fixes & Mitigations:
* **Increase npm Timeout and Retries**: Set conservative fetch and retry configs to handle the packet drops:
  ```bash
  npm config set fetch-retry-maxtimeout 120000
  npm config set fetch-retry-mintimeout 20000
  npm config set fetch-retries 10
  ```
* **Use Lighter Package Managers**: Use `pnpm` or `yarn` which perform less concurrent network activity and consume fewer CPU cycles inside the emulation layer.
* **Override the Default DNS Resolver**: By default, QEMU SLIRP routes DNS through `10.0.2.3`. Change it inside the VM's `/etc/resolv.conf` to a public DNS:
  ```
  nameserver 1.1.1.1
  nameserver 8.8.8.8
  ```
* **Restrict Concurrency**: If using npm, limit the maximum socket concurrency:
  ```bash
  npm config set maxsockets 3
  ```

---

### 2. Can't upgrade the Linux kernel inside the VM (stuck at `6.6.x`, Issue #18)

The VM boots using QEMU's `-kernel` and `-initrd` flags, which load `vmlinuz-virt` and `initramfs-virt` from the APK's bundled assets — **not** from the guest's `/boot/` directory. This is by design:
* The host-side kernel must match the modules compiled into `base.qcow2`. A mismatch causes a kernel panic at boot.
* Android's app sandbox prevents mounting the QCOW2 overlay to extract a guest-side kernel before QEMU starts.

**To upgrade the kernel**, the project maintainer must:
1. Build a new Alpine rootfs with the desired kernel version using `scripts/build_qcow2.sh`.
2. Copy the matching `vmlinuz-virt` and `initramfs-virt` into `android/app/src/main/assets/vm/`.
3. Bump `ASSETS_VERSION` in `VmManager.kt` (currently `"v26"`).
4. Build and release a new APK.

**What users can do**: Run `apk upgrade` to update userland packages (OpenSSH, Python, etc.) — those changes persist across reboots. Only the kernel itself requires an APK update.

---

### 3. Terminal commands are slow, delayed, or laggy (even simple ones like `ls`)

Users often notice input lag and delayed execution inside the terminal. While this can feel like network latency, it is **not caused by SLIRP networking**. 
* **Root Cause**: This is entirely due to **TCG (Tiny Code Generator) CPU emulation overhead** (~3x performance penalty on native ARM64 devices, or 10x-25x on x86_64 emulators due to Berberis translation). Every character typed and command executed requires translating ARM64 instructions to the host CPU in software.

#### How to Fix/Mitigate Slowness:
* **Run on Native ARM64 Hardware**: Run the app on a physical ARM64 Android device instead of an x86_64 Android Emulator. This removes the translation layer and speeds up execution significantly.
* **Disable Reverse DNS Lookup in sshd**: By default, `sshd` tries to look up the host IP, causing delays. Add or uncomment the following line in `/etc/ssh/sshd_config` inside the VM, then restart the sshd service:
  ```
  UseDNS no
  ```
  Restart service: `rc-service sshd restart`
* **Cap Guest Memory & Cores**: Capping the guest VM at **512 MB** and **1 or 2 vCPUs** in Settings prevents host device swap thrashing and CPU starvation.

---

### 4. VNC / Graphical UI and GPU hardware acceleration (Issue #17)

Currently, Linxr is configured for command-line access.
* **Recommended Solutions**:
  * **VNC Display**: You can install a headless desktop environment (e.g. XFCE) and VNC server (e.g. `x11vnc` or `tigervnc`) inside the Alpine VM, and connect to `localhost:5900` from Android using any external VNC client app.
  * **GPU Acceleration**: Native QEMU hardware-accelerated virtualization (via VirGL/OpenGL bindings) is not supported due to Android's strict SELinux sandbox policies and lack of direct EGL context access inside standard app processes. Software rendering can be configured but has low FPS.

---

## Project Structure

```
alpine/
├── android/
│   └── app/src/main/
│       ├── assets/vm/          # kernel, initramfs, base.qcow2.gz
│       ├── kotlin/com/ai2th/linxr/
│       │   ├── MainActivity.kt
│       │   ├── AlpineApp.kt
│       │   ├── VmManager.kt    # QEMU launcher + asset manager
│       │   └── VmService.kt    # foreground service
│       └── res/mipmap-*/       # launcher icons
├── assets/
│   ├── ai2th_logo.png          # company logo
│   └── linxr_icon.png          # app icon (512px)
├── lib/
│   ├── main.dart               # app root, home screen
│   ├── screens/
│   │   ├── terminal_screen.dart  # SSH terminal, multi-tab, auto-reconnect
│   │   ├── settings_screen.dart  # vCPU / RAM / disk sliders
│   │   └── about_screen.dart     # company info, license, dependencies
│   └── services/
│       └── vm_platform.dart    # platform channel + VmState
├── scripts/
│   ├── build_apk.sh            # Docker-based APK builder
│   ├── build_aab.sh            # Docker-based AAB builder (Play Store)
│   ├── build_qcow2.sh          # Alpine qcow2 builder (ARM64 Docker)
│   ├── _build_rootfs.sh        # rootfs bootstrap (runs inside Docker)
│   └── gen_icons.py            # generates all launcher icon sizes
├── LICENSE
└── pubspec.yaml
```

---

## Open Source Components

| Component | License | Purpose |
|---|---|---|
| [Flutter](https://flutter.dev) | BSD-3-Clause | Cross-platform UI |
| [dartssh2](https://pub.dev/packages/dartssh2) | MIT | Pure-Dart SSH2 client |
| [xterm](https://pub.dev/packages/xterm) | BSD-3-Clause | Terminal emulator widget |
| [provider](https://pub.dev/packages/provider) | MIT | State management |
| [QEMU](https://www.qemu.org) | GPL-2.0 | Machine emulator |
| [Alpine Linux](https://alpinelinux.org) | MIT / GPL | Guest OS |
| [OpenSSH](https://www.openssh.com) | BSD | SSH server in guest |

---

## License

```
MIT License

Copyright (c) 2026 AI2TH

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## About AI2TH

**Applied Intelligence To Tackle Hardships**

AI2TH builds developer tools that bring powerful computing environments to constrained devices.

---

*Linxr — run Linux anywhere.*
