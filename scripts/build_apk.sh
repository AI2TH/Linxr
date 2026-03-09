#!/bin/bash
# Build the Flutter Android APK entirely inside Docker.
# alpine/ is self-contained — no external dependencies needed.
#
# Usage:
#   ./scripts/build_apk.sh            # debug build (default)
#   ./scripts/build_apk.sh release    # release build
#
# Output:
#   build/linxr-debug.apk   or
#   build/linxr-release.apk
#
# Requirements: Docker only. No Flutter, Java, or Android SDK on the host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_TYPE="${1:-debug}"
IMAGE_NAME="linxr-builder"
OUTPUT_DIR="${PROJECT_ROOT}/build"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# ── Build the builder image if it doesn't exist ───────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "=== Building Docker build environment (first run — ~10 min) ==="
    docker build \
        --platform linux/amd64 \
        -f "${PROJECT_ROOT}/docker/Dockerfile.build" \
        -t "${IMAGE_NAME}" \
        "${PROJECT_ROOT}"
    echo ""
fi

echo "=== Building Flutter APK (${BUILD_TYPE}) inside Docker ==="
echo "Project : ${PROJECT_ROOT}"
echo "Output  : ${OUTPUT_DIR}/linxr-${BUILD_TYPE}.apk"
echo ""

docker run --rm \
    --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/workspace:ro" \
    -v "${OUTPUT_DIR}:/out" \
    "${IMAGE_NAME}" \
    bash -c '
set -e
git config --global --add safe.directory /opt/flutter 2>/dev/null || true

echo "--- Step 1: Scaffold fresh Flutter project ---"
flutter create \
    --no-pub \
    --project-name linxr \
    --org com.ai2th.linxr \
    --platforms android \
    /tmp/build

echo ""
echo "--- Step 2: Apply our sources ---"
cd /tmp/build

cp -r /workspace/lib/.                                  lib/
cp    /workspace/pubspec.yaml                           pubspec.yaml
cp    /workspace/analysis_options.yaml                  . 2>/dev/null || true

mkdir -p assets
cp -r /workspace/assets/.                              assets/

cp    /workspace/android/app/build.gradle               android/app/build.gradle
cp    /workspace/android/app/src/main/AndroidManifest.xml \
                                                        android/app/src/main/AndroidManifest.xml
cp    /workspace/android/build.gradle                   android/build.gradle
cp    /workspace/android/settings.gradle                android/settings.gradle
cp    /workspace/android/gradle.properties              android/gradle.properties

rm -rf android/app/src/main/kotlin/
cp -r /workspace/android/app/src/main/kotlin            android/app/src/main/

cp -r /workspace/android/app/src/main/res/.             android/app/src/main/res/

mkdir -p android/app/src/main/assets
cp -r /workspace/android/app/src/main/assets/.          android/app/src/main/assets/

mkdir -p android/app/src/main/jniLibs
cp -r /workspace/android/app/src/main/jniLibs/.         android/app/src/main/jniLibs/

[ -f /workspace/android/app/debug.keystore ] && \
    cp /workspace/android/app/debug.keystore android/app/debug.keystore || true

echo ""
echo "--- Step 2b: Fix Gradle wrapper to 8.3 ---"
sed -i "s|distributionUrl=.*|distributionUrl=https\://services.gradle.org/distributions/gradle-8.3-all.zip|" \
    android/gradle/wrapper/gradle-wrapper.properties

printf "flutter.sdk=/opt/flutter\nsdk.dir=/opt/android-sdk\n" > android/local.properties

echo ""
echo "--- Step 3: flutter pub get ---"
flutter pub get

echo ""
echo "--- Step 3b: Generate launcher icons ---"
dart run flutter_launcher_icons

echo ""
echo "--- Step 4: flutter build apk ('"${BUILD_TYPE}"') ---"
flutter build apk --'"${BUILD_TYPE}"' 2>&1 || true

echo ""
echo "--- Step 5: Copy APK to output ---"
APK_SRC="build/app/outputs/flutter-apk/app-'"${BUILD_TYPE}"'.apk"
APK_OUT="linxr-'"${BUILD_TYPE}"'.apk"
if [ -f "$APK_SRC" ]; then
    cp "$APK_SRC" /out/$APK_OUT
    echo "APK size: $(du -sh /out/$APK_OUT | cut -f1)"
else
    echo "ERROR: APK not found at $APK_SRC"
    ls -la build/app/outputs/flutter-apk/ 2>/dev/null || true
    exit 1
fi
'

echo ""
echo "Build complete: ${OUTPUT_DIR}/linxr-${BUILD_TYPE}.apk"
echo ""
echo "Install on device:"
echo "  adb install ${OUTPUT_DIR}/linxr-${BUILD_TYPE}.apk"
