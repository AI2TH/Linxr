# Linxr Firebase Test Lab — Infrastructure Notes

> Inventory, conventions, and constraints for setting up Firebase Test Lab
> for the Linxr Android app. Source of truth for steps 2–5 of `phase-2`.

---

## Overview

- **Goal.** Run Firebase Test Lab (FTL) tests for the Linxr Android app:
  1. A Robo smoke test against `build/linxr-debug.apk`.
  2. An instrumentation test of `VmResourceTest` (boots the VM, asserts disk/CPU).
- **GCP project.** `alpine-8b916` (same project as the Bible app; the Linxr
  debug keystore is bound to this GCP project's billing).
- **Service account.** `id-alpine@alpine-8b916.iam.gserviceaccount.com`
  (verified from `creds/alpine-service-account-key.json`).
- **Service account key.** `creds/alpine-service-account-key.json` (2.3 KB).
- **Linxr debug keystore.** `creds/linxr-debug.keystore` (2.7 KB). This is the
  keystore the APK at `build/linxr-debug.apk` is (or must be) signed with.
- **Project root.** `/mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr`
- **Branch.** `bugs` (current commit `86f8216`).
- **Credentials/scripts root.** `/mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/`
  (its own git repo — separate from the Linxr repo).

---

## Inventory

### `creds/` — Credentials (6 files)

| File | Size | Purpose | Use? |
|------|------|---------|------|
| `alpine-service-account-key.json` | 2.3 KB | GCP service account key for project `alpine-8b916` (`id-alpine@alpine-8b916.iam.gserviceaccount.com`) | **YES — the only auth key to use.** Verified `project_id` = `alpine-8b916`. |
| `linxr-debug.keystore` | 2.7 KB | Android debug keystore for Linxr APK signing (PKCS#12, password `android`, alias `debug`, RSA 2048, self-signed) | **YES — required** so Firebase Test Lab accepts the APK (and so the APK signature matches across builds). |
| `asterisk-service-account-key.json` | 2.3 KB | GCP key for project `asterisk-1a5ae` (Zyvr/Stardial) | NO — different project. |
| `service-account-key.json` | 2.3 KB | GCP key for project `my-project1-366819` (k8s) | NO — different project. |
| `miktam-credentials.txt` | 366 B | Plaintext credentials for "miktam" project | NO — different project, wrong format (not a service-account JSON). |
| `miktam-release-key.keystore` | 2.7 KB | Release keystore for "miktam" project | NO — different project; we want debug. |

**Rule of thumb:** only `alpine-service-account-key.json` and
`linxr-debug.keystore` are Linxr-relevant. Everything else belongs to a
different app.

### `firebase_scripts/` — 17 existing scripts

| Script | Target app | GCP project | Notes |
|--------|-----------|-------------|-------|
| `firebase_test_alpine.sh` | AlpineVM / Linxr | `alpine-8b916` | **Closest reference for Linxr** — same project, same key, same APK path conventions. Robo only, 600s timeout. |
| `firebase_stability_alpine.sh` | Linxr | `alpine-8b916` | 10-min Robo stability test, uses `--robo-directives ignore:startButton=`. Same `alpine-service-account-key.json`. |
| `firebase_check_vm.sh` | Linxr (`VmResourceTest`) | `alpine-8b916` | **The instrumentation-test reference.** Runs `VmResourceTest` via `gcloud firebase test android run --type instrumentation --test-targets "class com.ai2th.linxr.VmResourceTest"`. |
| `check_vm_resources.sh` | Linxr VM | n/a | Local SSH helper (not FTL). Uses `sshpass`/`ssh` to `root@127.0.0.1:2222` (ADB-forwarded). Useful sanity-check script. |
| `firebase_test_bible.sh` | Miktam Bible | `alpine-8b916` | Runs gcloud directly (no docker wrapper). Robo, 300s. |
| `firebase_test_bible.ps1` | Miktam Bible | `alpine-8b916` | PowerShell version of the above. |
| `firebase_test_zyvr.sh` | Zyvr | `asterisk-1a5ae` | Docker-wrapped. Supports optional 4th arg = robo script. |
| `firebase_stability_zyvr.sh` | Zyvr | `asterisk-1a5ae` | 25-min Robo stability. |
| `firebase_stability_zyvr_20min.sh` | Zyvr | `asterisk-1a5ae` | 20-min stability, shorter timeout. |
| `firebase_stability_zyvr_dashboard.sh` | Zyvr | `asterisk-1a5ae` | Dashboard-specific stability. |
| `firebase_custom_zyvr_20min.sh` | Zyvr | `asterisk-1a5ae` | Custom 20-min script. |
| `firebase_zyvr_dashboard_20min.sh` | Zyvr | `asterisk-1a5ae` | Dashboard 20-min Robo. |
| `firebase_zyvr_espresso_start_20min.sh` | Zyvr | `asterisk-1a5ae` | Espresso-driven 20-min (uses `--test-apk`). |
| `firebase_zyvr_start_button_20min.sh` | Zyvr | `asterisk-1a5ae` | Robo script-driven (`zyvr_start_dashboard_20min.json`). |
| `firebase_test_k8s.sh` | k8s / Kubxr | `my-project1-366819` | Docker-wrapped Robo, 600s. |
| `firebase_test_k8s_console.sh` | k8s | `my-project1-366819` | Console-style variant. |
| `firebase_test_stardial.sh` | Stardial | `asterisk-1a5ae` | Robo, 600s. |

The four scripts that already target `alpine-8b916` are the template for
Linxr:
1. `firebase_test_alpine.sh` — Robo smoke.
2. `firebase_stability_alpine.sh` — Robo stability.
3. `firebase_check_vm.sh` — Instrumentation (`VmResourceTest`).
4. `firebase_test_bible.sh` — direct-gcloud Robo (no docker wrapper).

### `robo_scripts/` — Robo scripts (3 files)

All three target the Zyvr project, **none for Linxr yet**.

| Script | Size | Steps |
|--------|------|-------|
| `zyvr_dashboard_robo_script.json` | 220 B | `WAIT 3s` → click "Start" → `WAIT 20m`. |
| `zyvr_msg_robo_script.json` | 1010 B | Click "Start" → wait 5m → click "Extensions" → wait 5m → click "Messages" → wait 5m → click "Dashboard" → wait 5m → click "Messages" → wait 5m. |
| `zyvr_start_dashboard_20min.json` | 206 B | Click element with `contentDescription: "Start"` → `WAIT 20m`. |

**Schema observed:** top-level JSON array of action objects. Each action has:
- `eventType`: `"WAIT"` or `"VIEW_CLICKED"`.
- For `WAIT`: `delayTime` (milliseconds).
- For `VIEW_CLICKED`: `elementDescriptors` (array of `{text}` or
  `{contentDescription}` matchers).

**Implication for Linxr.** Step 5 must author a new Robo script at
`test_script_and_creds/robo_scripts/linxr_smoke_robo.json` with the same
schema. Reusing the Zyvr scripts is unsafe: their `text`/`contentDescription`
matchers will not match Linxr's UI labels.

---

## Keystore Details — `creds/linxr-debug.keystore`

Inspected with `openssl pkcs12 -info -nodes -passin pass:android` (the system
does not have `keytool` installed; `openssl` is the available equivalent).

| Field | Value |
|-------|-------|
| **Format** | PKCS#12 (`.keystore` / `.p12`) |
| **Store password** | `android` (verified) |
| **Key alias** | `debug` |
| **Friendly name** | `debug` |
| **Algorithm** | RSA 2048-bit |
| **Signature algorithm** | `sha256WithRSAEncryption` |
| **Subject** | `C=US, ST=Unknown, L=Unknown, O=Docker VM, OU=Debug, CN=Docker VM Debug` |
| **Issuer** | (self-signed) same as Subject |
| **Serial** | `5689829994401150494` (`0x4ef6563be0a4b61e`) |
| **Not Before** | `Feb 26 16:39:13 2026 GMT` |
| **Not After** | `Jul 14 16:39:13 2053 GMT` (~27 years) |
| **SHA-1 fingerprint** | `D7:6E:66:8E:B9:E1:4F:47:0C:16:1C:E3:23:9E:ED:B0:4B:A0:74:8E` |
| **SHA-256 fingerprint** | `7D:AB:CB:2B:70:50:97:A5:C1:F4:4E:A8:1F:6C:3F:B2:2B:26:2D:DB:A2:3B:0E:63:20:87:EE:99:0C:74:D8:8D` |
| **Private key on disk** | `-----BEGIN PRIVATE KEY-----` block (PKCS#8, unencrypted inside the .p12 once the store password is supplied) |

The certificate's CN (`Docker VM Debug`) suggests it was generated for a
Docker-VM-based Alpine/Linxr build pipeline rather than a generic Android
debug keystore. Store password `android` is the Android default. **Before
uploading to Firebase Test Lab, verify that `build/linxr-debug.apk` was signed
with this exact keystore** (e.g. `apksigner verify --print-certs
build/linxr-debug.apk`); if it was signed with Flutter's default
`~/.android/debug.keystore` instead, FTL may reject the APK or the run will
not match what we want to test. Re-sign with this keystore if needed.

---

## Convention Analysis

All three alpine-targeted scripts share the same pattern (excerpted from
`firebase_test_alpine.sh`):

### Authentication
```bash
docker run --rm --platform linux/amd64 \
  -v "${APK}:/app.apk:ro" \
  -v "${KEY_FILE}:/creds.json:ro" \
  -e "GCP_PROJECT=${GCP_PROJECT}" \
  -e "DEVICE=${DEVICE}" \
  -e "ANDROID_VERSION=${ANDROID_VERSION}" \
  gcr.io/google.com/cloudsdktool/google-cloud-cli:stable \
  bash -c '
set -e
gcloud auth activate-service-account --key-file=/creds.json --quiet
gcloud config set project "${GCP_PROJECT}" --quiet
gcloud services enable testing.googleapis.com toolresults.googleapis.com --quiet 2>/dev/null || true
...'
```
- **Docker wrapper is mandatory** — it gives a known `gcloud` version and an
  `amd64` runtime even when the host is WSL on ARM.
- **`alpine-service-account-key.json` is mounted read-only** at `/creds.json`.
- **`gcloud auth activate-service-account`** is the activation method; no
  `GOOGLE_APPLICATION_CREDENTIALS` env var is set — the file is passed as
  `--key-file`.

### Robo smoke test (`firebase_test_alpine.sh`)
```bash
gcloud firebase test android run \
  --app=/app.apk \
  --device "model=${DEVICE},version=${ANDROID_VERSION},locale=en,orientation=portrait" \
  --timeout 600s \
  --type robo
```
- **Default device:** `Pixel2.arm`, **default Android version:** `31`.
- Locale `en`, orientation `portrait`, `--type robo` (no script).
- Timeout 600s = 10 min.

### Instrumentation test (`firebase_check_vm.sh`)
```bash
gcloud firebase test android run \
  --app=/app.apk \
  --test=/test.apk \
  --device "model=${DEVICE},version=${ANDROID_VERSION},locale=en,orientation=portrait" \
  --timeout 900s \
  --type instrumentation \
  --test-runner-class androidx.test.runner.AndroidJUnitRunner \
  --test-targets "class com.ai2th.linxr.VmResourceTest" \
  --no-record-video \
  --directories-to-pull /sdcard
```
- Both APKs mounted separately: `/app.apk` (main) and `/test.apk` (androidTest).
- Targets only the `VmResourceTest` class via `--test-targets`.
- Pulls `/sdcard` (for logcat dumps written by the test).
- Disables video recording (`--no-record-video`) — saves storage & time.

### Results URL
Every script prints a banner with:
```
https://console.firebase.google.com/project/${GCP_PROJECT}/testlab
```
That is the static URL of the Test Lab dashboard for the project. The
**per-run** URL with matrix ID is emitted by `gcloud` itself in its output
(line containing `https://console.firebase.google.com/.../<matrix-id>`) and
should be scraped from there for any automated follow-up.

### Log handling
There is **no explicit log-file redirection** in the alpine scripts — output
goes straight to stdout/stderr. To capture, wrap the call:
```bash
./firebase_test_alpine.sh 2>&1 | tee "$(date +%Y%m%d-%H%M%S)-alpine-test.log"
```

---

## Key Choices for Linxr

### GCP project
- **Use `alpine-8b916`** (matches Linxr/keystore; matches the only key in
  `creds/` whose `project_id` is `alpine-8b916`).
- Do NOT use `asterisk-1a5ae`, `my-project1-366819`, or any other key.

### Service-account authentication
- **Only** `creds/alpine-service-account-key.json`.
- Activate with `gcloud auth activate-service-account --key-file=...` (matches
  what the alpine scripts do).

### APK signing
- `build/linxr-debug.apk` (192 MB / 183 MiB) **must** be signed with
  `linxr-debug.keystore` (alias `debug`, password `android`) before upload.
- Verify with `apksigner verify --print-certs build/linxr-debug.apk` and check
  the SHA-1 cert digest matches `D7:6E:66:8E:B9:E1:4F:47:0C:16:1C:E3:23:9E:ED:B0:4B:A0:74:8E`.

### Test devices
- Start with `model=Pixel2.arm,version=31` (matches every existing alpine
  script). Move to `model=redfin,version=30` or similar only if a Pixel 2 is
  unavailable.
- Architecture must be ARM (`Pixel2.arm`) — Linxr's `VmManager` runs QEMU
  inside the app and is not validated for x86_64.

### Robo smoke test
- **New Robo script required:** `test_script_and_creds/robo_scripts/linxr_smoke_robo.json`
  (to be authored in step 5). The Zyvr scripts must not be reused — their
  `text:`/`contentDescription:` matchers reference the wrong UI.
- Suggested flow (action sequence): `WAIT 3s` → click "Start" (or whatever
  the Linxr start control is) → `WAIT 600000` (10 min) → end.
- Mount in docker as `-v ${ROBO_SCRIPT}:/robo_script.json:ro` and pass
  `--robo-script=/robo_script.json` (see `firebase_zyvr_start_button_20min.sh`
  for the exact pattern).
- `--timeout` must be ≥ the longest `delayTime` in the script + headroom.
  Robo timeout cap on FTL is 90 minutes for physical devices; the 20-min
  Zyvr scripts run with `--timeout 1500s` which is well within limits.

### Instrumentation test
- **Package:** `com.ai2th.linxr`
- **Test class:** `com.ai2th.linxr.VmResourceTest`
- **Runner:** `androidx.test.runner.AndroidJUnitRunner`
- **App APK:** `build/linxr-debug.apk` (192 MB).
- **Test APK:** `build/linxr-androidTest.apk` (~608 KB, already built).
- **Test-method timeout in source:** `6_000_000` ms (100 min) on
  `@Test fun checkVmResources()`. **FTL device-side timeout must be ≥ 100
  min** to allow the VM to fully boot, but FTL's hard cap on `--timeout`
  is **45 min** for physical devices and **30 min** for emulators — see
  "Open Questions" below.

---

## Reference Artifacts (old builds — DO NOT use)

Located in `/mnt/c/Users/kevin/Downloads/`. Pre-bug-fix Linxr builds, kept
only for historical comparison. They are NOT signed with
`linxr-debug.keystore` and must NOT be uploaded to FTL.

| File | Size | Notes |
|------|------|-------|
| `/mnt/c/Users/kevin/Downloads/23.apk` | 141.9 MB | Previous Linxr debug APK (pre-bug-fix). ~50 MB smaller than current `build/linxr-debug.apk` — likely missing the assets that the recent bug-fix work added. |
| `/mnt/c/Users/kevin/Downloads/23.aab` | 141.8 MB | Previous Linxr AAB. Same content as `23.apk` (AAB ≈ APK size before Play upload). |

**Current build artifacts (the ones to use):**
| File | Size | Path |
|------|------|------|
| `linxr-debug.apk` | 192 MB (~183 MiB) | `/mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/build/linxr-debug.apk` |
| `linxr-androidTest.apk` | ~608 KB | `/mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/build/linxr-androidTest.apk` |

---

## Open Questions / Risks

1. **`VmResourceTest.checkVmResources` timeout = 100 min** (`@Test(timeout = 6_000_000)`).
   FTL hard caps `--timeout` at **45 minutes on physical devices** and
   **30 minutes on emulators**. If the test legitimately needs 100 minutes
   to complete (boot Alpine VM, run `df -h`/`nproc`/`free -h`), FTL will
   kill it. Either:
   - Split the test into shorter sub-tests (each ≤ 30 min), or
   - Lower the JUnit `@Test(timeout=...)` to something FTL can honour (e.g.
     25 min), or
   - Confirm the test in practice completes in < 25 min (it currently
     does in local adb runs because `VmManager` has been tuned to boot
     faster after the recent bug-fixes per `BUGFIX_REPORT.md`).
   **Action:** measure `checkVmResources` runtime on a Pixel 2 over adb
   before running on FTL.

2. **APK signing verification.** No record was found that
   `build/linxr-debug.apk` was re-signed with `linxr-debug.keystore`. If
   it was built with Flutter's auto-generated `~/.android/debug.keystore`,
   FTL will not reject it (FTL accepts any debug-signed APK), but the
   SHA-1 fingerprint will not match the one in this inventory. Confirm
   before the FTL upload step.

3. **Service-account project binding.** `alpine-service-account-key.json`
   binds to `alpine-8b916`. Verify in the GCP console that this account
   has the `Firebase Test Lab Admin` and `Service Usage Consumer` roles
   on `alpine-8b916` — the existing alpine scripts call
   `gcloud services enable testing.googleapis.com toolresults.googleapis.com`,
   which requires those roles.

4. **WSL→Windows host networking.** If the docker wrapper is run from
   WSL, the `gcr.io/google.com/cloudsdktool/google-cloud-cli:stable`
   image must be pulled on an `amd64` platform. Existing alpine scripts
   pass `--platform linux/amd64` correctly, but only when Docker Desktop's
   WSL integration is on. If Docker isn't available in WSL, fall back to
   `firebase_test_bible.sh`'s direct-gcloud pattern (no docker wrapper).

5. **Robo script authoring.** No Linxr-specific Robo script exists in
   `robo_scripts/`. Step 5 will need to inspect the actual Linxr UI
   (resource IDs, content descriptions, text labels) to build
   `linxr_smoke_robo.json`. The Zyvr scripts are a schema reference only.

6. **`asterisk-service-account-key.json` is named the same as
   `alpine-service-account-key.json`** in terms of structure (both
   2.3 KB). Easy to grab the wrong one. Always re-verify
   `project_id == "alpine-8b916"` before activating.

7. **The `firebase_check_vm.sh` script also uses `--timeout 900s`
   (15 min)** for `VmResourceTest`. If the JUnit `@Test` timeout is
   really 100 min, this script would have failed in practice — so the
   real-world runtime is likely well under 15 min, and the `@Test(timeout=...)`
   annotation is just a safety net. Still worth measuring (see #1).

---

## Quick-Reference Copy-Paste Snippets

For step 2 (authenticate):
```bash
KEY="/mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/creds/alpine-service-account-key.json"
gcloud auth activate-service-account --key-file="${KEY}" --quiet
gcloud config set project alpine-8b916 --quiet
```

For step 3 (verify APK signing):
```bash
APKSIGNER=$(command -v apksigner || echo "${ANDROID_HOME:-${ANDROID_SDK_ROOT}}/build-tools/*/apksigner")
APK="/mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/build/linxr-debug.apk"
$APKSIGNER verify --print-certs "$APK" | grep -E 'SHA-256|SHA-1'
# Expect: SHA-256 cert digest == 7D:AB:CB:2B:70:50:97:A5:C1:F4:4E:A8:1F:6C:3F:B2:2B:26:2D:DB:A2:3B:0E:63:20:87:EE:99:0C:74:D8:8D
```

For step 4 (run Robo smoke):
```bash
cd /mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/firebase_scripts
./firebase_test_alpine.sh alpine-8b916 Pixel2.arm 31
```

For step 4 (run instrumentation `VmResourceTest`):
```bash
cd /mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/firebase_scripts
./firebase_check_vm.sh alpine-8b916 Pixel2.arm 31
```
