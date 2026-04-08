---
title: "feat: Add sshd for remote access while in TDM mode"
type: feat
status: active
date: 2026-04-08
---

# feat: Add sshd for Remote Access in TDM Mode

## Overview

While the iMac is running in Target Display Mode, there is no interactive shell available — only the TTY hotkeys on tty2–tty5. Adding an SSH server (sshd) lets you connect over Ethernet to inspect state, run commands, or control TDM remotely without a physical keyboard on the iMac.

## Requirements

- **Auth**: public-key only; no password auth (the `tc` user has no password by default)
- **Network**: Ethernet only; no WiFi packages needed
- **Build failure**: do not fail the build if no `authorized_keys` file is provided — sshd still runs; login just won't be possible until a key is added

## Proposed Solution

Four concrete changes:

1. **One-time host key generation** — a `generate-ssh-keys.sh` script the user runs once on their Mac. Writes stable host keys to `files/tdm/etc/ssh/`. These are baked into the ISO via the existing `tdm.tcz` packaging path, giving clients a stable host fingerprint across reboots.

2. **Static `sshd_config`** — committed to `files/tdm/etc/ssh/sshd_config`. Key-only auth, no root login, explicit `HostKey` paths.

3. **User public key** — user drops their public key into `files/ssh/authorized_keys` before building. `build.sh` copies it to `${tdm_dir}/home/tc/.ssh/authorized_keys` just before `mksquashfs`. If the file is absent or empty, the build continues with a warning.

4. **openssh.tcz** — downloaded via `tce-load -w openssh` in a new Stage 4c. Added to `onboot.lst` after `tdm.tcz`. TinyCore's openssh tce.installed script finds the pre-generated host keys (from tdm.tcz, mounted first) and starts sshd.

### Why not generate host keys inside Docker?

`ssh-keygen` requires squashfs mount privileges to install via `tce-load -i` — unavailable in the standard (non-privileged) Docker run. Generating on the Mac host (which ships with ssh-keygen) is simpler and more reliable. The keys are stable across builds because they're committed to the local repo (private keys gitignored).

### `onboot.lst` ordering

tdm.tcz must be mounted before openssh's tce.installed runs, so the config and host keys are on disk when sshd starts:

```
tdm.tcz        ← provides /etc/ssh/sshd_config, host keys, authorized_keys
hid-apple.tcz
openssh.tcz    ← tce.installed finds existing keys, starts sshd
```

This order is preserved naturally: tdm.tcz is added in Stage 3, openssh.tcz in the new Stage 4c.

---

## Implementation Phases

### Phase 1: Host Key Generation Script

**File:** `generate-ssh-keys.sh` (new, repo root, chmod +x)

```sh
#!/bin/sh
# Run once on the build host to create stable SSH host keys for the TDM image.
# Keys are written into files/tdm/etc/ssh/ and baked into tdm.tcz at build time.
# Private keys are gitignored; re-run this script if you need to rotate them.
set -e
mkdir -p files/tdm/etc/ssh
ssh-keygen -t ed25519 -f files/tdm/etc/ssh/ssh_host_ed25519_key -N "" -C "" -q
ssh-keygen -t rsa     -b 4096 -f files/tdm/etc/ssh/ssh_host_rsa_key -N "" -C "" -q
echo "Host keys written to files/tdm/etc/ssh/"
echo "Add your public key to files/ssh/authorized_keys before building."
```

**Also add to `.gitignore`:**

```
files/tdm/etc/ssh/ssh_host_*_key
```

(Public `.pub` files are fine to commit. Private keys are not sensitive for a LAN-only device, but gitignoring them is conventional and avoids accidental exposure if the repo ever becomes public.)

**Success criteria:** `files/tdm/etc/ssh/ssh_host_ed25519_key` and `ssh_host_rsa_key` exist after running the script.

---

### Phase 2: Static sshd_config

**File:** `files/tdm/etc/ssh/sshd_config` (new, committed)

```
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

The `Subsystem` path follows TinyCore's convention (`/usr/local/...`). Verify against the actual openssh.tcz layout during testing; update if the sftp-server binary is at a different path. Omitting the Subsystem line is also acceptable if sftp is not needed.

**Success criteria:** `sshd -T -f /etc/ssh/sshd_config` reports no errors (run inside a booted TinyCore instance or after extracting openssh.tcz with unsquashfs).

---

### Phase 3: User Public Key Placeholder

**File:** `files/ssh/authorized_keys` (new, empty, committed)

```
# Add your SSH public key here (one per line, ssh-ed25519 or ssh-rsa format).
# Example:
# ssh-ed25519 AAAA... user@host
```

This file is copied into the image by `build.sh` in Phase 4. Committed empty so the build path always exists; users populate it before building.

**Success criteria:** File exists at `files/ssh/authorized_keys`; build proceeds whether it is empty or populated.

---

### Phase 4: build.sh Changes

Two changes to `files/build.sh`:

#### 4a — Copy authorized_keys before mksquashfs (Stage 3)

Insert before the existing `mksquashfs` call in Stage 3:

```sh
# copy SSH authorized_keys into tdm package if provided
if [ -s /tmp/build/ssh/authorized_keys ]; then
    mkdir -p ${tdm_dir}/home/tc/.ssh
    cp /tmp/build/ssh/authorized_keys ${tdm_dir}/home/tc/.ssh/authorized_keys
    chmod 700 ${tdm_dir}/home/tc/.ssh
    chmod 600 ${tdm_dir}/home/tc/.ssh/authorized_keys
    printf "SSH authorized_keys included in tdm.tcz\n"
else
    printf "WARNING: files/ssh/authorized_keys is absent or empty — sshd will run but no keys are authorized\n"
fi

# warn if host keys are missing (user forgot to run generate-ssh-keys.sh)
if [ ! -f ${tdm_dir}/etc/ssh/ssh_host_ed25519_key ]; then
    printf "WARNING: SSH host keys not found in ${tdm_dir}/etc/ssh/\n"
    printf "  Run ./generate-ssh-keys.sh before building to get a stable host fingerprint.\n"
    printf "  Without host keys, TinyCore's openssh will generate ephemeral keys at each boot.\n"
fi
```

The `-s` test skips copying if the file is empty (comment-only placeholder).

#### 4b — Download openssh.tcz (new Stage 4c)

Add after the existing Stage 4b (hid-apple) block:

```sh
# acquire openssh extension
printf "## STAGE 4c: Acquire openssh\n"

if sudo -u tc tce-load -w openssh 2>/dev/null && \
   [ -f /tmp/tce/optional/openssh.tcz ]; then
    cp /tmp/tce/optional/openssh.tcz \
       ${tinycore_dir}/Core-current/cde/optional/
    echo "openssh.tcz" >> ${tinycore_dir}/Core-current/cde/onboot.lst
    printf "openssh.tcz added to image\n"
else
    printf "WARNING: could not download openssh.tcz — SSH will not be available at boot\n"
fi
```

**Success criteria:**
- `Core-remastered.iso` contains `cde/optional/openssh.tcz`
- `cde/onboot.lst` lists `tdm.tcz` before `openssh.tcz`
- Build completes without error regardless of whether openssh download succeeded

---

### Phase 5: README Update

Add a "Remote Access (SSH)" section to `README.md`:

- One-time setup: run `./generate-ssh-keys.sh`, add public key to `files/ssh/authorized_keys`
- Rebuild the ISO
- Connect: `ssh tc@<imac-ip>` (find IP via router DHCP table or `arp -a`)
- Note: DHCP is used; no static IP configured by default

---

## Alternative Approaches Considered

| Approach | Reason Rejected |
|----------|----------------|
| Generate host keys inside Docker at build time | Requires squashfs mount privileges (`tce-load -i`) not available in non-privileged containers |
| Generate host keys at TinyCore boot (ephemeral) | Client warns about host key change on every reboot; poor UX |
| Password authentication | `tc` has no password; setting one in build script means it's hardcoded in the ISO |
| WiFi support | Requires additional packages (firmware, wpa_supplicant); Ethernet is sufficient |

---

## Acceptance Criteria

### Build
- [ ] `generate-ssh-keys.sh` creates host keys in `files/tdm/etc/ssh/` on a macOS host
- [ ] Build succeeds with an empty `files/ssh/authorized_keys` (warning printed, no failure)
- [ ] Build succeeds with a populated `files/ssh/authorized_keys`
- [ ] `Core-remastered.iso` contains `cde/optional/openssh.tcz` and `cde/optional/tdm.tcz`
- [ ] `onboot.lst` lists `tdm.tcz` before `openssh.tcz`

### Runtime
- [ ] `ssh tc@<imac-ip>` connects successfully using the key from `authorized_keys`
- [ ] Password authentication is rejected
- [ ] Root login is rejected
- [ ] `lsmod` and other diagnostic commands work over SSH
- [ ] TDM hotkeys (tty2–tty5) continue to work after sshd is running

### Non-Regression
- [ ] hid-apple keyboard mapping still works (hid-apple.tcz still loads)
- [ ] TDM on/off/toggle still functions
- [ ] Boot flow unchanged; sshd adds no observable boot delay

---

## Dependencies & Prerequisites

- macOS build host with `ssh-keygen` (standard; ships with macOS)
- TinyCore package repo accessible during Docker build (existing requirement)
- Ethernet connection on the iMac at boot (DHCP)

## Risk Analysis

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| openssh.tcz not in TinyCore x86_64 repo | Low | Package exists in 17.x repo; confirmed available |
| openssh tce.installed does not auto-start sshd | Low-Medium | If confirmed, add `/usr/sbin/sshd` to `files/tdm/opt/bootlocal.sh` (runs after all tce.installed scripts) |
| sftp-server path in sshd_config incorrect | Low | Non-fatal: sshd still starts; only affects sftp subsystem. Fix by updating path or removing Subsystem line |
| DHCP lease not assigned before sshd starts | Very Low | sshd binds to all interfaces; connection works once IP is assigned |

## References

### Internal
- `files/build.sh:51–55` — existing Stage 3 mksquashfs block (insertion point for Phase 4a)
- `files/build.sh:103–104` — existing Stage 4b tail (insertion point for Phase 4c)
- `files/tdm/usr/local/tce.installed/tdm:1–30` — TDM init hook (no changes needed)

### External
- TinyCore x86_64 package repo: `http://tinycorelinux.net/17.x/x86_64/tcz/`
- openssh.tcz tce.installed behaviour: standard TinyCore pattern — generates missing host keys, then starts sshd
