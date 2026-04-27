#!/bin/bash
# Build the Flutter Android AAB entirely inside Docker.
# alpine/ is self-contained — no external dependencies needed.
#
# Usage:
#   ./scripts/build_aab.sh            # release build (default)
#   ./scripts/build_aab.sh debug      # debug build
#
# Output:
#   build/linxr-release.aab   or
#   build/linxr-debug.aab
#
# Requirements: Docker only. No Flutter, Java, or Android SDK on the host.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_TYPE="${1:-release}"
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

echo "=== Building Flutter AAB (${BUILD_TYPE}) inside Docker ==="
echo "Project : ${PROJECT_ROOT}"
echo "Output  : ${OUTPUT_DIR}/linxr-${BUILD_TYPE}.aab"
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

# Copy release signing config if present
if [ -f /workspace/android/key.properties ]; then
    cp /workspace/android/key.properties android/key.properties
    KEYSTORE_FILE=$(grep '"'"'^storeFile='"'"' android/key.properties | cut -d= -f2)
    [ -n "$KEYSTORE_FILE" ] && [ -f "/workspace/android/app/$KEYSTORE_FILE" ] && \
        cp "/workspace/android/app/$KEYSTORE_FILE" "android/app/$KEYSTORE_FILE" || true
fi

echo ""
echo "--- Step 3: flutter pub get ---"
flutter pub get

echo ""
echo "--- Step 3b: Generate launcher icons ---"
dart run flutter_launcher_icons

echo ""
echo "--- Step 4: flutter build appbundle ('"${BUILD_TYPE}"') ---"
flutter build appbundle --'"${BUILD_TYPE}"'

echo ""
echo "--- Step 5: Copy AAB to output ---"
AAB_SRC="build/app/outputs/bundle/'"${BUILD_TYPE}"'/app-'"${BUILD_TYPE}"'.aab"
AAB_OUT="linxr-'"${BUILD_TYPE}"'.aab"
if [ -f "$AAB_SRC" ]; then
    cp "$AAB_SRC" /out/$AAB_OUT
    echo "AAB size: $(du -sh /out/$AAB_OUT | cut -f1)"
else
    echo "ERROR: AAB not found at $AAB_SRC"
    ls -la build/app/outputs/bundle/ 2>/dev/null || true
    exit 1
fi
'

echo ""
echo "Build complete: ${OUTPUT_DIR}/linxr-${BUILD_TYPE}.aab"
