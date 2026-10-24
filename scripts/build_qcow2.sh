#!/bin/bash
# Build bare Alpine Linux base.qcow2 for Linxr.
# ARM64, openssh + sudo, root password: alpine
#
# Output: android/app/src/main/assets/vm/base.qcow2.gz
#
# Requirements: Docker only.
# Usage:
#   ./scripts/build_qcow2.sh

set -e
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (pwd -W 2>/dev/null || pwd))"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && (pwd -W 2>/dev/null || pwd))"
OUTPUT_DIR="${PROJECT_ROOT}/android/app/src/main/assets/vm"

CONTAINER_CMD="docker"
if ! command -v docker &>/dev/null; then
    if command -v podman &>/dev/null; then
        CONTAINER_CMD="podman"
    else
        echo "ERROR: Docker or Podman is required."
        exit 1
    fi
fi

mkdir -p "${OUTPUT_DIR}"

echo "=== Building Alpine Linux base.qcow2 for Linxr ==="
echo "Platform : linux/arm64 (aarch64)"
echo "Packages : openssh + sudo + bash"
echo "Output   : "${OUTPUT_DIR}"/base.qcow2.gz"
echo ""

ALPINE_TAG="alpine:${ALPINE_VERSION:-3.20}"
echo "Base Image: ${ALPINE_TAG}"

"${CONTAINER_CMD}" run --rm \
    --platform linux/arm64 \
    -v "${OUTPUT_DIR}:/out" \
    -v "${SCRIPT_DIR}/_build_rootfs.sh:/build.sh:ro" \
    "${ALPINE_TAG}" \
    sh /build.sh

echo ""
echo "=== base.qcow2.gz ready: $(du -sh "${OUTPUT_DIR}"/base.qcow2.gz | cut -f1) ==="
echo "Rebuild APK: ./scripts/build_apk.sh"
