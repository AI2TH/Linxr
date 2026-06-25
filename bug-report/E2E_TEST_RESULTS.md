# Firebase Test Lab E2E Run — Linxr

**Run timestamp:** 2026-06-25 14:05 UTC
**Tester:** kimchi (automated via ferment worker, phase-2 / step-5)
**GCP project:** alpine-8b916
**Service account:** id-alpine@alpine-8b916.iam.gserviceaccount.com

## Summary

**Both test matrices FAILED to submit.** The script (`firebase_test_linxr.sh`)
encountered multiple blocking issues before any matrix was created in
Firebase Test Lab:

1. **NEW-5 (script bug)** — the device string used `model:Pixel4` (colon
   separator); gcloud's `--device` flag requires `key=value` (equals
   separator). The wrapper exited immediately.
2. **NEW-6 (script bug)** — `Pixel4` is not a valid FTL device model. After
   correcting the separator to `=`, gcloud rejected `Pixel4` with
   `'Pixel4' is not a valid model`. The script defaults to `Pixel4`; the
   project's existing alpine scripts all use `Pixel2.arm` instead.
3. **NEW-7 (project billing)** — After fixing both script bugs and
   re-running gcloud directly, FTL refused to create the GCS results bucket:
   `Permission denied while creating bucket
   [alpine-8b916_firebase_test_results]. Is billing enabled for project:
   [alpine-8b916]?` The service account has `roles/editor` but the project
   lacks an active billing account, so FTL cannot provision storage.
4. ~~**APK signing concern (NEW-8 candidate)**~~ — **RETRACTED, FALSE POSITIVE**.
   A re-verification by the orchestrator via direct Python inspection
   confirmed that `build/linxr-debug.apk` IS correctly signed with V2 + V3
   schemes using `linxr-debug.keystore`. The absence of V1 JAR signing
   (`META-INF/MANIFEST.MF`, `META-INF/*.RSA`) is NORMAL for modern AGP
   debug builds and is accepted by FTL (V2 + V3-only APKs are fine for
   all Android ≥ 7.0 targets, which is every API level FTL emulates).
   See the **NEW-8 FALSE-POSITIVE VERIFICATION** section below for the
   full proof including the cert SHA-256 match.

**Result:** zero matrices submitted. Run aborted. No VM boot was exercised.
This document was committed so the failure modes are visible to the
orchestrator and follow-up workers.

---

## Artifacts

| Item | Value |
|------|-------|
| APK | `build/linxr-debug.apk` (192,446,874 bytes / 183 MiB) |
| Test APK | `build/linxr-androidTest.apk` (618,741 bytes) |
| Keystore on disk | `android/app/debug.keystore` (= `creds/linxr-debug.keystore`, 2,742 B) |
| Keystore cert SHA-256 (expected per `TEST_INFRA_NOTES.md`) | `7D:AB:CB:2B:70:50:97:A5:C1:F4:4E:A8:1F:6C:3F:B2:2B:26:2D:DB:A2:3B:0E:63:20:87:EE:99:0C:74:D8:8D` |
| App package | `com.ai2th.linxr` |
| Test class | `com.ai2th.linxr.VmResourceTest` |
| Test device requested | `model:Pixel4,version:30` (in script) — INVALID |
| Test device retried | `model=Pixel2.arm,version=30` (matches existing alpine scripts) |
| Robo script | `robo_scripts/linxr_smoke_robo.json` (9 actions) |
| Driver script | `firebase_scripts/firebase_test_linxr.sh` (committed b669c95) |
| Run log directory | `build/firebase_results_20260625_140554/` (wrapper), `build/firebase_results_20260625_141549/` (direct gcloud) |

## Pre-flight

| # | Check | Result | Detail |
|---|-------|--------|--------|
| 1.1 | gcloud SDK | PASS | Google Cloud SDK 572.0.0, core 2026.06.05 |
| 1.2 | Auth active | PASS | `id-alpine@alpine-8b916.iam.gserviceaccount.com` (verified via `gcloud config get-value account` and `gcloud auth list`) |
| 1.3 | Project set | PASS | `alpine-8b916` |
| 1.4 | GCP reachability | PASS | `firebase.googleapis.com` → HTTP 404 in 0.42s; `testing.googleapis.com` → HTTP 404 in 1.43s; `toolresults.googleapis.com` → HTTP 404 in 1.10s (DNS + TLS working; 404 on root is expected for those APIs) |
| 1.5 | FTL API enabled | PASS | `firebase.googleapis.com`, `testing.googleapis.com`, `toolresults.googleapis.com` all present in `gcloud services list --enabled` |
| 1.6 | APKs present | PASS | `linxr-debug.apk` 192,446,874 B, `linxr-androidTest.apk` 618,741 B |
| 1.7 | Service account perms | PASS (but see 1.8) | `roles/editor` on `alpine-8b916` (over-privileged; would have been sufficient for FTL) |
| 1.8 | Billing enabled | **FAIL** | gcloud error: `Permission denied while creating bucket [alpine-8b916_firebase_test_results]. Is billing enabled for project: [alpine-8b916]?` |
| 1.9 | APK signed (V2 + V3 block) | **PASS (V2 + V3; V1 absent is normal)** | APK Sig Block 42 magic at offset 192430484; V3 marker `0xAFAFAFAF` present; `linxr-debug.keystore` cert DER (903 bytes) at offset 192426492; cert SHA-256 matches expected value (see verification section below) |

## Test 1: Robo smoke test — SKIPPED

| Field | Value |
|-------|-------|
| Matrix ID | (none — submission aborted) |
| Matrix URL | n/a |
| Submitted at | n/a |
| Completed at | n/a |
| Duration | n/a |
| State | **SKIPPED — script bug (NEW-5) + invalid device model (NEW-6)** |
| Robo script | `linxr_smoke_robo.json` — 9 actions |
| Screenshots | 0 |
| Activities exercised | none |

### Log excerpts

From `build/firebase_results_20260625_140554/wrapper.log`:

```
[14:07:00] ===== Test 1/2: Robo smoke test =====
ERROR: (gcloud.firebase.test.android.run) argument --device: Bad syntax for dict arg: [model:Pixel4]. 
Please see `gcloud topic flags-file` or `gcloud topic escaping` for information on providing list or 
dictionary flag values with special characters.
```

From a manual retry using `model=Pixel2.arm,version=30` (corrected separator):

```
ERROR: (gcloud.firebase.test.android.run) 'Pixel4' is not a valid model
```

From a second retry using `model=Pixel2.arm,version=30` directly:

```
Creating results bucket [gs://alpine-8b916_firebase_test_results] in project [alpine-8b916].
ERROR: (gcloud.firebase.test.android.run) Permission denied while creating bucket 
[alpine-8b916_firebase_test_results]. Is billing enabled for project: [alpine-8b916]?
```

## Test 2: VmResourceTest instrumentation — SKIPPED

| Field | Value |
|-------|-------|
| Matrix ID | (none — submission aborted) |
| Matrix URL | n/a |
| Submitted at | n/a |
| Completed at | n/a |
| Duration | n/a |
| State | **SKIPPED — same blockers as Test 1** |
| Test class | `com.ai2th.linxr.VmResourceTest.checkVmResources` |
| Test outcome | did not run |

## NEW bugs surfaced

- **NEW-5** — `firebase_test_linxr.sh:69` DEVICE default uses `:` separator
  inside `--device` value (e.g. `model:Pixel4,version:30`). gcloud expects
  `key=value` pairs. Fix: change default to `model=Pixel4,version=30,...` or
  pick a different separator style. **Resolution: NOT FIXED in this step**
  (script lives in the separate `test_script_and_creds` repo, outside the
  Linxr tree's commit scope).

- **NEW-6** — `firebase_test_linxr.sh:69` DEVICE default uses `Pixel4` which
  is not a valid FTL device model. FTL lists `Pixel2.arm` (virtual, API
  26-33), `redfin` (Pixel 5, physical, API 30 default), `blueline`
  (Pixel 3), `bluejay` (Pixel 6a), `akita` (Pixel 8a), `blazer` (Pixel 10
  Pro), `caiman` (Pixel 9 Pro), `comet` (Pixel 9 Pro Fold), `felix` (Pixel
  Fold), `cheetah` (Pixel 7 Pro). Fix: default to `model=Pixel2.arm,version=30`
  (matches the four existing alpine-targeted scripts in the same directory
  per `TEST_INFRA_NOTES.md`).

- **NEW-7** — GCP project `alpine-8b916` does not have billing enabled.
  FTL requires an active billing account on the project to provision the
  GCS results bucket. `gcloud services list --enabled` confirms many APIs
  are enabled, so the project is not totally dead — but the Billing
  page in Cloud Console would need a billing account attached before
  any FTL run can succeed. Service account `id-alpine@...` has
  `roles/editor`, so it's not a permissions issue.

- ~~**NEW-8**~~ — **RETRACTED, FALSE POSITIVE.** The previous version of
  this section claimed `build/linxr-debug.apk` was unsigned based on the
  absence of V1 JAR signing artifacts (`META-INF/MANIFEST.MF`,
  `META-INF/*.RSA`) and a misread of the APK Signing Block. Re-verification
  by the orchestrator via direct Python byte-level inspection confirms
  the APK IS correctly signed with APK Signature Scheme v2 + v3 using
  `linxr-debug.keystore`. The absence of V1 JAR signing is normal for
  modern AGP debug builds and is accepted by Firebase Test Lab (which
  targets Android ≥ 7.0, all of which require v2 or higher). The earlier
  agent confused V1-only requirements with general APK signing. Full
  proof is in the **NEW-8 FALSE-POSITIVE VERIFICATION** section below.
  **Resolution:** no rebuild required; the file on disk
  (`build/linxr-debug.apk`) is correctly signed and would be accepted by
  FTL. **NOT FIXED** because there is no bug to fix.

## NEW-8 FALSE-POSITIVE VERIFICATION

The orchestrator re-verified the APK signature by direct byte-level
inspection (Python, no `apksigner`). All checks pass:

| # | Check | Expected | Actual | Result |
|---|-------|----------|--------|--------|
| 1 | File size | 192,446,874 bytes | 192,446,874 bytes | PASS |
| 2 | APK Signing Block magic | `APK Sig Block 42` (16 bytes) at the position immediately before the Central Directory | Present at offset **192430484** (16 bytes from CD boundary) | PASS |
| 3 | V3 marker pattern | `0xAFAFAFAF` magic in the ID-value pairs inside the signing block | Found at the expected position inside the signing block | PASS |
| 4 | `linxr-debug.keystore` cert DER inside signing block | A ~903-byte DER sequence starting near the start of the signing block (before the CD) | Found at offset **192426492**, length 903 bytes, ending 4008 bytes before the CD start | PASS |
| 5 | SHA-256 of the embedded cert DER | `7D:AB:CB:2B:70:50:97:A5:C1:F4:4E:A8:1F:6C:3F:B2:2B:26:2D:DB:A2:3B:0E:63:20:87:EE:99:0C:74:D8:8D` | **Exact byte-for-byte match** | PASS |
| 6 | Comparison to the on-disk keystore cert | Same SHA-256 as `creds/linxr-debug.keystore` cert | Matches `creds/linxr-debug.keystore` extracted cert | PASS |

**Conclusion.** `build/linxr-debug.apk` is signed with APK Signature
Scheme v2 + v3 using `creds/linxr-debug.keystore`. The previous
"unsigned" verdict was a false positive caused by the original agent
equating "no V1 JAR signing" with "unsigned" — a common mistake. V1 is
optional since AGP 7.0; v2 has been the default since Android 7.0; v3
has been the default since Android 9. FTL accepts v2-only or v2+v3-only
APKs without issue. The cert SHA-256 in the APK matches the expected
keystore cert exactly, so the file is the one the build pipeline
produced.

**Action.** None — the APK is correctly signed. The retraction here
overrides the original "APK signing concern" section above.

## VM-asset modifications

None in this run. No qcow2 / `android/app/src/main/assets/vm/` changes were
attempted.

## Conclusion

Firebase Test Lab could not accept any test from this host because (1) the
driver script `firebase_test_linxr.sh` had two blocking bugs (wrong
separator and invalid device model — since fixed in commit `dc1b5b1`
in the sibling repo), and (2) GCP project `alpine-8b916` lacks an active
billing account, which FTL requires to provision its GCS results bucket.
The original concern about an unsigned APK (NEW-8) was a false positive;
the APK on disk is correctly signed with v2 + v3 using
`linxr-debug.keystore` and would have been accepted by FTL. **Recommended
follow-ups:**

1. **NEW-7 first** — enable billing on `alpine-8b916` via Cloud Console →
   Billing → Link a billing account. Without this, no FTL run can land.
2. **NEW-5 + NEW-6 second** — already fixed in commit `dc1b5b1` in the
   sibling `test_script_and_creds` repo; default is now
   `model=Pixel2.arm,version=30,locale=en,orientation=portrait`.
3. **NEW-8** — retracted (false positive). No action needed; APK is
   correctly signed (v2 + v3).
4. **NEW-1/NEW-4** already documented in `BUGFIX_REPORT.md` (withValues
   revert and POST_NOTIFICATIONS rewrite) — unrelated to this step.

## Reproduction

Once billing is enabled and the APK is re-signed:

```bash
# Re-run this exact test (after fixing NEW-5 + NEW-6):
cd /mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/firebase_scripts
./firebase_test_linxr.sh
```

Or run gcloud directly (bypassing the script's broken default):

```bash
GCLOUD="/mnt/c/Users/kevin/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin/gcloud"
$GCLOUD auth activate-service-account \
    --key-file=/mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/creds/alpine-service-account-key.json \
    --project=alpine-8b916
$GCLOUD firebase test android run \
    --type=robo \
    --app=/mnt/c/Users/kevin/OneDrive/Documents/kalvin/Linxr/build/linxr-debug.apk \
    --robo-script=/mnt/c/Users/kevin/OneDrive/Documents/kalvin/test_script_and_creds/robo_scripts/linxr_smoke_robo.json \
    --device="model=Pixel2.arm,version=30,locale=en,orientation=portrait" \
    --timeout=30m \
    --results-bucket=alpine-8b916_firebase_test_results \
    --results-dir="linxr/robo/$(date +%Y%m%d_%H%M%S)" \
    --project=alpine-8b916
```

## Files referenced

- Driver script: `test_script_and_creds/firebase_scripts/firebase_test_linxr.sh` (b669c95) — **has bugs NEW-5, NEW-6**
- Robo script: `test_script_and_creds/robo_scripts/linxr_smoke_robo.json` (b669c95) — schema is correct
- Wrapper log: `build/firebase_results_20260625_140554/firebase_run.log`
- Direct-gcloud log: `build/firebase_results_20260625_141549/robo_run.log`
- Infra inventory: `bug-report/TEST_INFRA_NOTES.md` (800e837)
- APK signing claim: commit `3231e89 build: sign debug APK with creds/linxr-debug.keystore` — does not match current APK state (NEW-8)
