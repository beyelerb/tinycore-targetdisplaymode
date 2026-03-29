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

echo "==> Pre-installing build packages via privileged container..."
echo "    (bash, libisoburn, git, gcc, compiletc + dependencies)"
CID=$(docker run -d --privileged "${INIT_TAG}" /bin/sh -c 'sleep 3600')

# Fix permissions and set up TinyCore runtime environment
docker exec "${CID}" /bin/sh -c '
set -e
chown 0:0 /etc/sudoers
chmod u+s /usr/bin/sudo
mkdir -p /tmp/tce/optional /home/tc /usr/local/tce.installed /etc/sysconfig /mnt/tcz
chown -R tc:staff /tmp/tce /home/tc
ln -sf /tmp/tce /etc/sysconfig/tcedir
echo "http://tinycorelinux.net" > /opt/tcemirror
'

# Download packages and their dependencies as tc user
docker exec -u tc "${CID}" /bin/sh -c '
tce-load -w bash.tcz libisoburn.tcz git.tcz gcc.tcz compiletc.tcz
'

# Mount each squashfs package and copy its contents into the filesystem
docker exec "${CID}" /bin/sh -c '
for pkg in /tmp/tce/optional/*.tcz; do
    name=$(basename "$pkg")
    if mount -t squashfs -o loop,ro "$pkg" /mnt/tcz 2>/dev/null; then
        cp -a /mnt/tcz/. / 2>/dev/null || true
        umount /mnt/tcz
        echo "  installed $name"
    else
        echo "  WARNING: could not mount $name, skipping"
    fi
done
rm -rf /tmp/tce/optional/
'

echo "==> Committing image as ${IMAGE_TAG}..."
docker commit "${CID}" "${IMAGE_TAG}"
docker rm -f "${CID}"
docker rmi "${INIT_TAG}" 2>/dev/null || true

echo "==> Cleaning up..."
rm -rf "${EXTRACT_DIR}" "${ROOTFS_FILE}" "${COREPURE_FILE}"

echo "==> Done. Base image ${IMAGE_TAG} is ready."
