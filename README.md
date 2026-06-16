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
