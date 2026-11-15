# Linxr

**Bare Alpine Linux VM & Docker Container Workstation on Android — no root required.**

Linxr runs a full Alpine Linux environment on a linux-virt kernel inside a QEMU virtual machine on any arm64 Android device. Access it through the built-in multi-tab SSH terminal, the Containers dashboard, the file manager, the Linux desktop, or any external SSH client. No root, no Termux, no special hardware.

---

## 🚀 Features in v3.4.0

- **1-Click Marketplace & Recipe Store** — Discover and 1-click deploy curated container stacks (k3s Kubernetes, Nginx, Redis, PostgreSQL, VS Code Server, Ollama AI, Portainer, Node.js, Python, Tailscale) or write, import, and share your own custom community recipes.
- **Chrome & Web Browser Port Forwarding** — Automatic port forwarding (`8080`, `3000`, `8000`, `5000`, `8443`, `9000`, `8088->80`, `11434`) letting you test web applications and dashboards in Chrome directly on your phone.
- **Alpine Linux VM** — Alpine Linux on a linux-virt kernel, a fast custom init (OpenRC tools installed), Dropbear SSH, `sudo`, `bash`, and full `apk` package repository access.
- **Native Docker & Kubernetes Engine** — Complete Docker container management and k3s Kubernetes runtime support with cgroup2 subtree controllers and `/dev/kmsg` support.
- **Native Docker Dashboard (Pockr Merged)** — Complete Docker container management under the **Containers** tab (pull images, launch containers, stream live container logs).
- **Live System & VM Serial Log Console** — Real-time kernel serial logs (`dmesg`, `init`, `sshd`) streaming directly on the Home screen for 100% boot transparency.
- **Virtio-9P Storage & SAF Folder Picker** — Direct POSIX storage sharing at `/storage/emulated/0/LinxrShare` mounted inside guest VM at `/mnt/sdcard`, plus Android Storage Access Framework (SAF) folder picker in Settings.
- **FastTrack OCI & Linux Desktop** — Daemonless `podman`/`crun` containers (or Docker on demand), and an Openbox/XFCE4 desktop over noVNC (ports 6080 and 5900), opened from the Home screen.
- **Multi-Tab Terminal** — Up to 5 concurrent SSH sessions with auto-reconnect, keepalive, and specialized touch control key bar (`Tab`, `Esc`, `Ctrl+C`, `Ctrl+D`, `Ctrl+Z`).
- **Dynamic Resource Controls** — Configure vCPU count, RAM, and disk size in Settings.
- **No Root Required** — QEMU runs entirely as a standard Android userland application sandbox.

---

## 📸 Screenshots

| Home — Stopped | Home — Live Serial Logs | Terminal (`linxr:~#`) |
|---|---|---|
| ![Home stopped](https://ai2th.github.io/screenshots/linxr/01-home-stopped.png) | ![Home running](https://ai2th.github.io/screenshots/linxr/02-home-running.png) | ![Terminal](https://ai2th.github.io/screenshots/linxr/03-terminal-running.png) |

| Containers Dashboard | Storage & Files | Settings & SAF Picker |
|---|---|---|
| ![Containers](https://ai2th.github.io/screenshots/linxr/04-container-running-active.png) | ![Files](https://ai2th.github.io/screenshots/linxr/05-files.png) | ![Settings](https://ai2th.github.io/screenshots/linxr/07-settings-scrolled.png) |

---

## 💬 Community & Discussion

Join our official community for technical discussions, feature requests, and support:
- 💬 **AI2TH Google Group:** [https://groups.google.com/g/ai2th](https://groups.google.com/g/ai2th)
- 📚 **DEV.to Engineering Series (16 parts):** [dev.to/ai2th/series/36674](https://dev.to/ai2th/series/36674)
- 🌐 **Official Website:** [https://ai2th.github.io/linxr.html](https://ai2th.github.io/linxr.html)

---

## 📱 Requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| Android OS | 8.0 (API 26) | Android 11.0+ |
| Architecture | arm64-v8a | arm64-v8a |
| Free Storage | ~300 MB (APK + VM base image) | 10 GB+ for Docker images |
| Device RAM | 2 GB | 4 GB+ |

---

## ⚡ Quick Start

1. Download the latest **Linxr** APK from [GitHub Releases](https://github.com/AI2TH/Linxr/releases/latest) or [Google Play Store](https://play.google.com/store/apps/details?id=com.ai2th.linxr).
2. Open **Linxr** → tap **Start VM**.
3. Watch real-time kernel boot logs stream inside the **System & VM Logs** console on the Home Screen.
4. Switch to the **Terminal** tab — it auto-connects as soon as SSH is active on `port 2222`.
5. The terminal logs in automatically. For other SSH clients, the root password is under **Settings → SSH access**.

### External SSH Connection

```bash
ssh root@localhost -p 2222
# Password: Settings → SSH access (generated per install)
```

---

## 🏗️ Architecture & Stack

```
Android Host (Flutter + Kotlin Userland App)
│
├── VmManager.kt          — QEMU lifecycle, asset extraction, SSH readiness probe
├── VmService.kt          — Android Foreground Service (keeps VM alive in background)
├── MainActivity.kt       — SAF document picker MethodChannel (pickFolder)
│
├── QEMU Engine (libqemu.so)
│   ├── Virtio-Net (SLIRP)— hostfwd 127.0.0.1:2222 -> 22, 127.0.0.1:7081 -> 7080 (API), app ports
│   └── Virtio-9P         — Shares /storage/emulated/0/LinxrShare with guest VM
│
└── Guest VM (Alpine Linux / linux-virt kernel)
    ├── Custom init       — Fast boot script (OpenRC tools installed)
    ├── Dropbear SSH      — SSH server listening on port 22 inside VM
    ├── Containers        — FastTrack podman/crun, or the Docker daemon on demand (vfs storage)
    └── api_server.py     — REST API bridging Flutter Containers tab to /var/run/docker.sock
```

### Disk & Asset Layout

| Asset File | Purpose |
|---|---|
| `base.qcow2` | Read-only Alpine rootfs (Dropbear, Docker, podman, sudo, python3 pre-installed) |
| `user.qcow2` | Writable QCOW2 overlay preserving all your files and Docker containers |
| `vmlinuz-virt` | Guest linux-virt kernel with Virtio drivers |
| `initramfs-virt` | Initial RAM filesystem |

---

## 🛠️ Building from Source

### Prerequisites
- Linux / macOS workstation with Docker (for cross-compiling rootfs and native QEMU libraries)
- Android SDK (API 31+)
- Flutter 3.x SDK

### 1 — Build the Alpine Base RootFS & QCOW2 Image
```bash
bash scripts/build_qcow2.sh
```
*Outputs: `android/app/src/main/assets/vm/base.qcow2.gz`, `vmlinuz-virt` and `initramfs-virt`*

> **Note:** the VM assets above and the QEMU binaries (`android/app/src/main/jniLibs/arm64-v8a/libqemu.so` and `libqemu_img.so`) are not committed to this repository. Build the VM assets with the step above and provide the QEMU libraries yourself before building the APK; without them the app installs but cannot start the VM (see [#32](https://github.com/AI2TH/Linxr/issues/32)). Each image records its Alpine and kernel versions in `/etc/linxr-release`.

### 2 — Build the Android APK
```bash
bash scripts/build_apk.sh debug     # Debug build
bash scripts/build_apk.sh release   # Release build (requires release keystore)
```
*Outputs: `build/linxr-debug.apk` or `build/linxr-release.apk`*

### 3 — Build Play Store Bundle (AAB)
```bash
bash scripts/build_aab.sh
```
*Outputs: `build/linxr-release.aab`*

### 4 — Install via ADB
```bash
adb install build/linxr-release.apk
```

---

## 🔑 Default Credentials

| Parameter | Default Value |
|---|---|
| Username | `root` |
| Password | Generated per install; shown under **Settings → SSH access** |
| Host key | Dropbear ed25519 key generated on first boot |

> 🔒 *The password is kept in Android Keystore and applied in the VM on every start. Settings → SSH access can also switch the VM to key-only login.*

---

## 📂 Project Structure

```
Linxr/
├── android/
│   └── app/src/main/
│       ├── assets/bootstrap/   # api_server.py, init_bootstrap.sh
│       ├── assets/vm/          # linux-virt kernel, initramfs, base.qcow2.gz
│       └── kotlin/com/ai2th/linxr/
│           ├── MainActivity.kt  # SAF pickFolder MethodChannel
│           ├── VmManager.kt     # QEMU launcher & SSH readiness probe
│           └── VmService.kt     # Foreground Service
├── lib/
│   ├── main.dart               # Main app layout & Home Screen
│   ├── constants.dart          # App constants & theme colors
│   ├── screens/
│   │   ├── terminal_screen.dart # Multi-tab SSH terminal emulator
│   │   ├── containers_screen.dart # Docker Container Dashboard & log viewer
│   │   ├── files_screen.dart    # Virtio-9P filesystem explorer
│   │   └── settings_screen.dart # vCPU/RAM/Disk sliders & SAF picker
│   └── services/
│       └── vm_platform.dart    # Platform Channels & VmState provider
├── scripts/
│   ├── build_apk.sh            # APK build script
│   ├── build_aab.sh            # Play Store AAB build script
│   ├── build_qcow2.sh          # QCOW2 Alpine image builder
│   └── _build_rootfs.sh        # Docker-based rootfs builder
├── CHANGELOG.md
├── LICENSE
└── pubspec.yaml
```

---

## 📜 Open Source Components & Licenses

| Component | License | Role |
|---|---|---|
| [Flutter](https://flutter.dev) | BSD-3-Clause | UI framework |
| [QEMU](https://www.qemu.org) | GPL-2.0 | ARM64 CPU & Machine Virtualization Engine |
| [Alpine Linux](https://alpinelinux.org) | MIT / GPL | Guest Linux Distribution |
| [Docker Engine](https://www.docker.com) | Apache-2.0 | Container Runtime |
| [dartssh2](https://pub.dev/packages/dartssh2) | MIT | Pure-Dart SSH2 client |
| [xterm.dart](https://pub.dev/packages/xterm) | BSD-3-Clause | Terminal emulator UI widget |

---

## 📄 License

Copyright (C) 2026 AI2TH.

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the full text.

---

## 🏢 About AI2TH

**Applied Intelligence To Tackle Hardships**

AI2TH builds developer tools and virtualization platforms that bring Linux environments to mobile and edge hardware without root access.

*Linxr — run Linux anywhere.*
