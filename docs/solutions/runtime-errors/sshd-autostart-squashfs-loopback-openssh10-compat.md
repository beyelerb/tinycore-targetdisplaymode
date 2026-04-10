---
title: "sshd auto-start in TinyCore ISO loopback boot with OpenSSH 10.0"
date: 2026-04-10
problem_type: runtime-errors
component: openssh / tce.installed boot hooks
symptoms:
  - openssh.tcz download fails via tce-load -w in non-privileged Docker container
  - sshd refuses to load host keys accessed through squashfs symlinks
  - authorized_keys inaccessible at runtime (root-owned in squashfs, tc user cannot read)
  - openssh init script fatally fails on DSA key type removed in OpenSSH 10.0
  - background polling loop killed after tce.installed exits
  - missing /var/lib/sshd privilege separation directory at time of sshd launch
  - DHCP not enabled — iMac has no IP address at boot
tags:
  - tinycore
  - openssh
  - sshd
  - squashfs
  - loopback-boot
  - docker-build
  - tcz-extensions
  - boot-scripting
  - openssh-10
related_files:
  - files/build.sh
  - files/ssh/authorized_keys
  - files/tdm/usr/local/etc/ssh/sshd_config
  - files/tdm/usr/local/tce.installed/tdm
  - generate-ssh-keys.sh
  - files/grub/grub.cfg
---

# sshd Auto-Start in TinyCore ISO Loopback Boot with OpenSSH 10.0

## Root Cause

TinyCore Linux in loopback ISO boot mode presents a layered filesystem where `.tcz` extensions are mounted as squashfs loopback devices and their contents **symlinked** into the live filesystem via `/tmp/tcloop/<package-name>/`. This has several consequences:

- Files inside `.tcz` extensions are read-only and appear as symlinks at their live paths
- Security-conscious daemons (sshd) refuse to use config files or key files that are symlinks or that have root ownership when a non-root user is expected
- TinyCore's process lifecycle sends `SIGHUP` to init after `tce.installed` hooks run, which kills ordinary background subshells
- TinyCore's bundled openssh init script tries to generate DSA host keys, which OpenSSH 10.0 removed entirely

## Solution

### 1. Download openssh.tcz via wget (not tce-load)

Non-privileged Docker containers cannot mount squashfs, so `tce-load -w` fails silently. Derive the TCZ URL from `TC_ISO_URL` and use `wget` directly. `openssl.tcz` is a required dependency and must be downloaded first.

```sh
# in files/build.sh — Stage 4c
TC_TCZ_URL="$(dirname $(dirname ${TC_ISO_URL}))/tcz"
OPENSSH_OK=1
for pkg in openssl openssh; do
    if wget -q "${TC_TCZ_URL}/${pkg}.tcz" \
       -O ${tinycore_dir}/Core-current/cde/optional/${pkg}.tcz; then
        echo "${pkg}.tcz" >> ${tinycore_dir}/Core-current/cde/onboot.lst
        printf "${pkg}.tcz added to image\n"
    else
        printf "WARNING: could not download ${pkg}.tcz — SSH will not be available at boot\n"
        OPENSSH_OK=0; break
    fi
done
```

### 2. Use the correct config path

TinyCore's openssh.tcz installs to `/usr/local/etc/ssh/`, **not** `/etc/ssh/`. Place `sshd_config` at `files/tdm/usr/local/etc/ssh/sshd_config`. Point `HostKey` and `AuthorizedKeysFile` at writable tmpfs paths (where they'll be copied at boot):

```
# files/tdm/usr/local/etc/ssh/sshd_config
Port 22
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
AuthorizedKeysFile /home/tc/.ssh/authorized_keys
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
Subsystem sftp /usr/local/lib/openssh/sftp-server
```

### 3. Copy keys from squashfs to writable tmpfs at boot

sshd performs strict ownership and permission checks. Files inside `.tcz` are symlinks into a read-only squashfs mount — sshd refuses them. Access the raw squashfs via `/tmp/tcloop/tdm/` and copy to writable paths in the `tce.installed` hook:

```sh
# copy SSH host keys from read-only squashfs to writable tmpfs
mkdir -p /etc/ssh
for key in ssh_host_ed25519_key ssh_host_rsa_key; do
    if [ -f /tmp/tcloop/tdm/usr/local/etc/ssh/${key} ]; then
        cp /tmp/tcloop/tdm/usr/local/etc/ssh/${key} /etc/ssh/${key}
        cp /tmp/tcloop/tdm/usr/local/etc/ssh/${key}.pub /etc/ssh/${key}.pub
        chmod 600 /etc/ssh/${key}
        chmod 644 /etc/ssh/${key}.pub
    fi
done

# copy authorized_keys with correct tc user ownership
if [ -f /usr/local/etc/ssh/authorized_keys ]; then
    mkdir -p /home/tc/.ssh
    cp /usr/local/etc/ssh/authorized_keys /home/tc/.ssh/authorized_keys
    chown -R tc:staff /home/tc/.ssh
    chmod 700 /home/tc/.ssh
    chmod 600 /home/tc/.ssh/authorized_keys
fi
```

> **Why `/tmp/tcloop/tdm/` and not the live path?**
> The live path (e.g. `/usr/local/etc/ssh/ssh_host_ed25519_key`) is a symlink into the squashfs. sshd refuses it. `/tmp/tcloop/tdm/usr/local/etc/ssh/ssh_host_ed25519_key` is the actual file in the squashfs mount — `cp` reads through without sshd's security checks applying.

### 4. Skip the openssh init script; call sshd directly

OpenSSH 10.0 removed DSA support. TinyCore's `/usr/local/etc/init.d/openssh` tries to generate DSA host keys and exits fatally. Call the binary directly:

```sh
/usr/local/sbin/sshd -f /usr/local/etc/ssh/sshd_config
```

### 5. Use nohup + polling loop in tce.installed

`tce.installed` hooks run before openssh.tcz is loaded (tdm.tcz is listed first in `onboot.lst`), so sshd can't be started immediately. TinyCore also sends `SIGHUP` after hooks run, killing plain `( ) &` background jobs. Use `nohup` with explicit redirection and poll for the sshd binary:

```sh
# in files/tdm/usr/local/tce.installed/tdm
nohup sh -c '
  i=0
  while [ $i -lt 30 ] && [ ! -x /usr/local/sbin/sshd ]; do
    sleep 1; i=$((i+1))
  done
  if [ -x /usr/local/sbin/sshd ]; then
    mkdir -p /var/lib/sshd && chmod 711 /var/lib/sshd
    /usr/local/sbin/sshd -f /usr/local/etc/ssh/sshd_config
  else
    echo "WARNING: openssh did not load within 30 seconds — sshd not started" | tee /dev/console
  fi
' </dev/null >/dev/null 2>&1 &
```

> **Why poll for the binary, not the init script?**
> The binary appears the instant openssh.tcz is squashfs-mounted. The init script also appears at that point, but calling it is unreliable (DSA failure). The binary path is the right signal.

> **Why `mkdir -p /var/lib/sshd` inside the loop?**
> The sshd binary becomes visible when openssh.tcz is mounted — before openssh's own `tce.installed` hook runs. The privsep directory `/var/lib/sshd` is created by that hook. At `i=0` the binary exists but the dir may not. Creating it explicitly removes the race.

### 6. Enable DHCP

TinyCore disables DHCP by default. Remove `nodhcp` from the kernel line in `grub.cfg`:

```diff
-linux (loop)/boot/vmlinuz64 waitusb=10 iso=LABEL=TINYCORE nodhcp
+linux (loop)/boot/vmlinuz64 waitusb=10 iso=LABEL=TINYCORE
```

TinyCore's init will run `udhcpc` (BusyBox, built into the base image) automatically on the Ethernet interface.

---

## TinyCore Service Checklist

Work through these before adding any new daemon.

### Networking
- Confirm `nodhcp` is absent from `grub.cfg`
- If the service needs a routable address, poll for it before starting the daemon

### Package Installation
- Never use `tce-load` inside a non-privileged Docker build container — use `wget` directly
- Check `.tcz.dep` and download all transitive dependencies
- Verify the TCZ URL matches your TinyCore major version

### Config File Paths
- Never assume standard Linux paths — TinyCore installs under `/usr/local/` by convention
- Inspect the package before writing config:
  ```sh
  wget http://tinycorelinux.net/17.x/x86_64/tcz/<pkg>.tcz.info
  unsquashfs -l <pkg>.tcz   # lists all file paths
  cat squashfs-root/usr/local/etc/init.d/<pkg>  # read the init script
  ```

### Writable Paths
- Any file a security-checking daemon reads (host keys, authorized_keys) must be **copied** to writable tmpfs — never rely on the squashfs symlink
- Source files from `/tmp/tcloop/<pkg>/` (the raw mount), not the live symlinked path
- Set strict permissions immediately after copying

### Init Script Compatibility
- Read the init script before calling it — it may reference removed features (DSA in OpenSSH 10.0)
- Prefer calling the daemon binary directly with explicit flags

### Boot Hook Ordering
- Use `nohup sh -c '...' </dev/null >/dev/null 2>&1 &` for any background job in `tce.installed`
- Do not assume that because a binary is visible, its `tce.installed` hook has finished

---

## Debugging Tips

**Add boot logging temporarily:**
```sh
nohup sh -c '
  echo "polling started" >> /var/log/sshd-boot.log
  # ... polling loop ...
  echo "sshd exited $?" >> /var/log/sshd-boot.log
' </dev/null >>/var/log/sshd-boot.log 2>&1 &
```
After boot: `cat /var/log/sshd-boot.log`

**Test sshd manually before encoding in a boot hook:**
```sh
mkdir -p /etc/ssh /var/lib/sshd
cp /tmp/tcloop/tdm/usr/local/etc/ssh/ssh_host_*_key /etc/ssh/
chmod 600 /etc/ssh/ssh_host_*_key
/usr/local/sbin/sshd -f /usr/local/etc/ssh/sshd_config -d
```
The `-d` flag runs in foreground and prints debug output for one connection — fastest way to catch privsep, key, or config errors before touching boot hooks.

**Verify nohup is effective after boot:**
```sh
ps | grep sshd
```
If sshd is absent with no log entry, the process was killed by the init HUP signal — `nohup` is missing or stdout/stderr aren't redirected.
