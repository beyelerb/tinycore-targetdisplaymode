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
INIT_TAG="${IMAGE_TAG}-init"
BASE_URL="http://tinycorelinux.net/${MAJOR}.x/x86_64/release/distribution_files"
ROOTFS_FILE="/tmp/rootfs64-${VERSION}.gz"
COREPURE_FILE="/tmp/corepure64-${VERSION}.gz"
EXTRACT_DIR="/tmp/tc-rootfs-${VERSION}"
PKGS_DIR="/tmp/tc-packages-${VERSION}"
MERGED_DIR="/tmp/tc-merged-${VERSION}"

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

echo "==> Importing rootfs as ${INIT_TAG}..."
chmod -R u+r "${EXTRACT_DIR}"
tar -C "${EXTRACT_DIR}" -c . | docker import - "${INIT_TAG}"

# Download packages using tce-load (download-only flag works without squashfs support)
echo "==> Downloading build packages via TinyCore tce-load..."
echo "    (bash, libisoburn, git, gcc, compiletc + all dependencies)"
mkdir -p "${PKGS_DIR}"
CID=$(docker run -d --privileged "${INIT_TAG}" /bin/sh -c 'sleep 3600')

docker exec "${CID}" /bin/sh -c '
set -e
chown 0:0 /etc/sudoers
chmod u+s /usr/bin/sudo
mkdir -p /tmp/tce/optional /home/tc /etc/sysconfig
chown -R tc:staff /tmp/tce /home/tc
ln -sf /tmp/tce /etc/sysconfig/tcedir
echo "http://tinycorelinux.net" > /opt/tcemirror
'
docker exec -u tc "${CID}" /bin/sh -c '
tce-load -w bash.tcz libisoburn.tcz git.tcz gcc.tcz compiletc.tcz
'
# Use docker cp instead of volume mount write (volume writes silently fail on macOS/Podman)
docker cp "${CID}:/tmp/tce/optional/." "${PKGS_DIR}/"
docker rm -f "${CID}"
docker rmi "${INIT_TAG}" 2>/dev/null || true

PKG_COUNT=$(ls "${PKGS_DIR}"/*.tcz 2>/dev/null | wc -l | tr -d ' ')
echo "==> ${PKG_COUNT} packages downloaded to ${PKGS_DIR}"

# Podman on macOS does not share /tmp paths via -v volume mounts.
# Instead, bake the packages into a temporary Alpine extractor image via
# docker build (build context is tarred and transferred, bypassing the issue).
EXTRACTOR_TAG="${IMAGE_TAG}-extractor"
cat > "${PKGS_DIR}/Dockerfile" << 'DOCKERFILE'
FROM alpine:latest
RUN apk add -q squashfs-tools
COPY *.tcz /packages/
RUN mkdir -p /rootfs && \
    for pkg in /packages/*.tcz; do \
        unsquashfs -f -d /rootfs "$pkg" > /dev/null 2>&1 || true; \
    done
DOCKERFILE

echo "==> Building extractor image (Alpine + packages)..."
docker build -q --load -t "${EXTRACTOR_TAG}" "${PKGS_DIR}/"

# Merge: start from the basic rootfs, then overlay extracted package files.
echo "==> Merging rootfs with extracted packages..."
rm -rf "${MERGED_DIR}"
cp -a "${EXTRACT_DIR}/." "${MERGED_DIR}/"
docker run --rm "${EXTRACTOR_TAG}" tar -C /rootfs -c . \
    | tar -C "${MERGED_DIR}" -x 2>/dev/null || true
docker rmi "${EXTRACTOR_TAG}" 2>/dev/null || true

find "${MERGED_DIR}" -name "._*" -delete 2>/dev/null || true
chmod -R u+r "${MERGED_DIR}" 2>/dev/null || true

echo "==> Importing combined rootfs as ${IMAGE_TAG}..."
tar -C "${MERGED_DIR}" -c . | docker import - "${IMAGE_TAG}"

echo "==> Cleaning up..."
rm -rf "${EXTRACT_DIR}" "${MERGED_DIR}" "${ROOTFS_FILE}" "${COREPURE_FILE}" "${PKGS_DIR}"

echo "==> Done. Base image ${IMAGE_TAG} is ready."
