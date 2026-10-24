#!/bin/bash
# Shared build setup for APK and AAB Docker builds.
# Source this from build_apk.sh or build_aab.sh.

set -e
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && (pwd -W 2>/dev/null || pwd))"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && (pwd -W 2>/dev/null || pwd))"
IMAGE_NAME="linxr-builder"
OUTPUT_DIR="${PROJECT_ROOT}/build"
if [ -d "/mnt/c/Users/kevin/.gradle" ]; then
    GRADLE_DIR="/mnt/c/Users/kevin/.gradle"
elif [ -n "${USERPROFILE}" ] && [ -d "${USERPROFILE}/.gradle" ]; then
    GRADLE_DIR="${USERPROFILE}/.gradle"
elif [ -d "${HOME}/.gradle" ]; then
    GRADLE_DIR="$(cd "${HOME}/.gradle" && (pwd -W 2>/dev/null || pwd))"
else
    mkdir -p "${HOME}/.gradle"
    GRADLE_DIR="${HOME}/.gradle"
fi
GRADLE_DIR="${GRADLE_DIR//\\//}"
mkdir -p "${GRADLE_DIR}"

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

# Build the builder image if it doesn't exist
if ! "${CONTAINER_CMD}" image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "=== Building container build environment (first run — ~10 min) ==="
    "${CONTAINER_CMD}" build \
        --platform linux/amd64 \
        -f "${PROJECT_ROOT}/docker/Dockerfile.build" \
        -t "${IMAGE_NAME}" \
        "${PROJECT_ROOT}"
    echo ""
fi