#!/bin/sh
# build-base-image.sh
# Bootstraps a local Docker base image for the TinyCorePure64 build environment.
# Must be run once before `docker build` when upgrading to a new TinyCore version.
#
# Usage: ./build-base-image.sh [VERSION]
#   VERSION defaults to 17.0

set -e

VERSION="${1:-17.0}"
MAJOR="${VERSION%%.*}"
IMAGE_TAG="localhost/tcl-core-x86_64:${VERSION}"
BASE_URL="http://tinycorelinux.net/${MAJOR}.x/x86_64/release/distribution_files"
ROOTFS_FILE="/tmp/rootfs64-${VERSION}.gz"
COREPURE_FILE="/tmp/corepure64-${VERSION}.gz"
EXTRACT_DIR="/tmp/tc-rootfs-${VERSION}"

echo "==> Building Docker base image ${IMAGE_TAG}"

echo "==> Downloading rootfs64.gz..."
wget -q --show-progress "${BASE_URL}/rootfs64.gz" -O "${ROOTFS_FILE}"

echo "==> Downloading corepure64.gz..."
wget -q --show-progress "${BASE_URL}/corepure64.gz" -O "${COREPURE_FILE}"

echo "==> Extracting cpio archives..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
cd "${EXTRACT_DIR}"
gzip -dc "${ROOTFS_FILE}"   | cpio -idm 2>/dev/null
gzip -dc "${COREPURE_FILE}" | cpio -idm 2>/dev/null
cd - >/dev/null

echo "==> Importing into Docker as ${IMAGE_TAG}..."
tar -C "${EXTRACT_DIR}" -c . | docker import - "${IMAGE_TAG}"

echo "==> Cleaning up..."
rm -rf "${EXTRACT_DIR}" "${ROOTFS_FILE}" "${COREPURE_FILE}"

echo "==> Done. Base image ${IMAGE_TAG} is ready."
