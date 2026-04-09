#!/bin/sh
# Run once on the build host to create stable SSH host keys for the TDM image.
# Keys are written into files/tdm/etc/ssh/ and baked into tdm.tcz at build time,
# giving SSH clients a stable host fingerprint across reboots.
#
# Re-run this script if you need to rotate the host keys.
# Private keys are gitignored; public keys are committed.
set -e

KEYDIR="$(dirname "$0")/files/tdm/usr/local/etc/ssh"
mkdir -p "${KEYDIR}"

ssh-keygen -t ed25519 -f "${KEYDIR}/ssh_host_ed25519_key" -N "" -C "" -q
ssh-keygen -t rsa -b 4096 -f "${KEYDIR}/ssh_host_rsa_key" -N "" -C "" -q

echo "Host keys written to ${KEYDIR}/"
echo "Add your SSH public key to files/ssh/authorized_keys before building."
