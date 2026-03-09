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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/android/app/src/main/assets/vm"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo "=== Building Alpine Linux base.qcow2 for Linxr ==="
echo "Platform : linux/arm64 (aarch64)"
echo "Packages : openssh + sudo + bash"
echo "Output   : ${OUTPUT_DIR}/base.qcow2.gz"
echo ""

docker run --rm \
    --platform linux/arm64 \
    -v "${OUTPUT_DIR}:/out" \
    -v "${SCRIPT_DIR}/_build_rootfs.sh:/build.sh:ro" \
    alpine:3.19 \
    sh /build.sh

echo ""
echo "=== base.qcow2.gz ready: $(du -sh ${OUTPUT_DIR}/base.qcow2.gz | cut -f1) ==="
echo "Rebuild APK: ./scripts/build_apk.sh"
