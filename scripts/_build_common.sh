#!/bin/bash
# Shared build setup for APK and AAB Docker builds.
# Source this from build_apk.sh or build_aab.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="linxr-builder"
OUTPUT_DIR="${PROJECT_ROOT}/build"

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required."
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# Build the builder image if it doesn't exist
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "=== Building Docker build environment (first run — ~10 min) ==="
    docker build \
        --platform linux/amd64 \
        -f "${PROJECT_ROOT}/docker/Dockerfile.build" \
        -t "${IMAGE_NAME}" \
        "${PROJECT_ROOT}"
    echo ""
fi