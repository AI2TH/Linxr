# Linxr — Improvements

What still needs work, in priority order. Items marked with a PR are partly done there; everything else is open. Last reviewed: November 2026 (after the code review in #34).

---

## P0 — Security

### 1. Every install shares the same SSH password and host keys
- **What:** SSH uses the fixed `root` / `alpine` password, and the Dropbear host keys are baked into `base.qcow2`, so every Linxr install has the same keys. A comment claims they are regenerated; they are not.
- **Why it matters:** with **Allow LAN access** on, anyone on the same Wi-Fi can log in as root, and an attacker can impersonate any user's VM.
- **How to fix:**
  1. Generate a random root password and a per-install Dropbear host key on first boot (`dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key`), and delete the baked keys from the image.
  2. Pass the password into the VM through QEMU `fw_cfg` (as the API token already is), store it in Android Keystore, and use it in the terminal's SSH client.
  3. Show the password in Settings with a copy button; offer key-only login as an option.

### 2. Community recipes can replace built-in ones and run as root
- **What:** recipes from `AI2TH/linxr-marketplace` run as root through `/vm/exec` and override built-in recipes with the same `id`. Several switch apk to plain `http`.
- **Why it matters:** whoever controls that repo's `main` decides what "k3s" or "nginx-native" does on every phone, over an unauthenticated channel.
- **How to fix:**
  1. Never let a remote recipe override a built-in `id`; show remote ones as "Community".
  2. Sign `recipes.json` (minisign or Ed25519), embed the public key in the app, and reject unsigned or badly signed catalogs.
  3. Reject recipes that downgrade apk to `http` in `validate.js`; show the full script before the first run.

### 3. `eval "$APP"` in `linxr-desktop.sh`
- **What:** the desktop app launcher evaluates its argument and builds JSON without escaping.
- **How to fix:** accept only an allow-list of launcher names (terminal, file manager, editor) and use `jq -n --arg` for JSON.

---

## P1 — Correctness

### 4. Disk resize needs an end-to-end test — #27, #34
Resize logic is fixed in #34 but only tested in a container. Add the E2E check: set a 16 GB disk, boot, assert `df -h /` reports more than 15 GB.

### 5. Settings shows "Auto" disk as free storage, but the app creates 4 GB
Show the real size that will be created, or make "Auto" mean a percentage of free storage with a clear cap.

### 6. k3s does not restart after a VM reboot
The custom `/sbin/init` never runs OpenRC, so the k3s service is not started again. Start k3s from `init_bootstrap.sh` when it is installed (`[ -x /usr/local/bin/k3s ] && k3s server ... &`), with the `GODEBUG` env file from #34.

### 7. Foreground service type and restarts
- `dataSync` is limited to 6 hours a day on Android 15; a long-running VM needs `specialUse` (with a Play Console declaration).
- `START_STICKY` can restart the service showing "VM is running" after the process died. Re-check VM state on restart, or use `START_NOT_STICKY`.

### 8. Recipe ports are not forwarded automatically — #31
When a recipe declares ports, offer to add them as forwards (with a collision check). SLIRP `hostfwd` is TCP-only here, so SIP over UDP 5060 needs a note or a UDP forward.

### 9. k3s TLS timings are unmeasured — #30
Measure `time kubectl get nodes` before and after on a device and record the numbers; apply the same install change to the community `k3s` recipe.

---

## P2 — Product

### 10. Show what is inside the VM — #33
Display Alpine and kernel versions (from `/etc/linxr-release`, added in #34) in Settings → About, and drop or explain the kernel version-string patch.

### 11. Optional apk mirror choice
The image defaults to `mirrors.aliyun.com`. Offer a mirror picker (Alpine CDN default) for users outside Asia.

### 12. Measure and publish real numbers
Idle CPU with FastTrack vs Docker, boot time, and RAM use on 2–3 reference phones, recorded in the README instead of estimates.

---

## P3 — Releases and docs

### 13. Releases without an APK, and source builds that cannot boot — #32, #23
- Attach APKs to v1.0.0, v1.1.6, v2.0.0 and v3.0.0, or mark them "source only".
- Publish the VM kernel, initramfs and `base.qcow2` as release assets with SHA-256 checksums, plus a `scripts/fetch_vm_assets.sh`, so a source build boots.
- Push the latest build to the Google Play production track (the listing is older than GitHub).

### 14. Bump `ASSETS_VERSION` when shipping a rebuilt base image
Shipping the rootfs changes from #34 needs the usual `ASSETS_VERSION` bump in `VmManager.kt`, which recreates `user.qcow2`. Warn users in the release notes that the VM disk is reset.

### 15. CI
There are no GitHub Actions workflows. Add one that runs `flutter analyze`, `flutter test`, `shellcheck` on `scripts/` and the bootstrap, and a Kotlin compile.
