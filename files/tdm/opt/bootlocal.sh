#!/bin/sh
# bootlocal.sh runs after all onboot.lst extensions are loaded.

# start sshd for remote access over Ethernet
/usr/local/etc/init.d/openssh start 2>/dev/null || true
