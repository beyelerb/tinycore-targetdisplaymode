---
title: "feat: Switch build to x86_64 (TinyCorePure64)"
type: feat
status: in-progress
date: 2026-03-29
---

# feat: Switch Build to x86_64 (TinyCorePure64)

## Overview

Switch the bootable image from 32-bit TinyCore Linux (x86) to 64-bit TinyCorePure64. All supported vintage iMacs (2009–mid 2014) have 64-bit CPUs. The 64-bit build gives access to more RAM, better compiler output for `smc_util`, and aligns with modern software expectations. The existing `hid-apple` module packaging and all boot infrastructure carry over cleanly — the main work is bootstrapping a new x86_64 Docker base image and pointing URLs at the x86_64 tree.

## Problem Statement / Motivation

The current build uses `linichotmailca/tcl-core-x86:latest` (32-bit) as the Docker build environment and downloads `TinyCore-17.0.iso` (x86). No pre-built x86_64 TinyCore Docker image exists on Docker Hub — `linichotmailca` maintains x86 only, and the original `tatsushid/tinycore` is abandoned at v11.0. The x86_64 base image must be bootstrapped from TinyCore's published `rootfs64.gz`.

## Proposed Solution

### Phase 1: Bootstrap the x86_64 Docker base image

Add a `build-base-image.sh` script that downloads TinyCore's `rootfs64.gz`, extracts the cpio archive, and imports it into Docker as `tcl-core-x86_64:17.0`. This is a one-time step that produces a local base image. The script is committed to the repo so it's reproducible.

```sh
# build-base-image.sh (new file)
wget http://tinycorelinux.net/17.x/x86_64/release/distribution_files/rootfs64.gz
mkdir /tmp/tc-rootfs
cd /tmp/tc-rootfs && zcat <path>/rootfs64.gz | cpio -idm 2>/dev/null
tar -C /tmp/tc-rootfs -c . | docker import - tcl-core-x86_64:17.0
```

### Phase 2: Update Dockerfile

Change the `FROM` line and the default `TC_ISO_URL`:

```dockerfile
# Dockerfile
FROM tcl-core-x86_64:17.0

ENV TC_ISO_URL="${TC_ISO_URL:-http://www.tinycorelinux.net/17.x/x86_64/release/TinyCorePure64-17.0.iso}"
```

### Phase 3: Verify build.sh requires no changes

The following already work for x86_64 with zero code changes:
- `TC_MODULES_URL` derived from `$(dirname ${TC_ISO_URL})/distribution_files/modules.gz`
- Kernel version regex `[0-9]+\.[0-9]+\.[0-9]+-tinycore[0-9]*` matches `tinycore64`
- `tce-load` running inside a 64-bit TC environment auto-targets the x86_64 package repo
- `mksquashfs`, `xorriso`, `cpio` usage is architecture-agnostic
- `smc_util` compiles natively — will produce a 64-bit binary automatically

The one item to verify: the ISO URL validation regex in `build.sh` line 27:
```sh
grep -Ee '^https?://(www\.)?tinycorelinux\.net/[0-9]+.*/.*\.iso'
```
This already accepts `TinyCorePure64-17.0.iso` — no change needed.

### Phase 4: README updates

- Add a "Prerequisites" or "Build" section documenting the one-time `build-base-image.sh` step
- Update architecture references from x86 to x86_64

## Technical Considerations

- **Base image lifecycle**: `tcl-core-x86_64:17.0` is a local Docker image. It must be rebuilt when upgrading to a future TinyCore version. The script should accept a version argument.
- **No Docker Hub publishing required**: the base image is built locally on demand. If CI is added later, the script runs as part of the pipeline setup.
- **rootfs64.gz vs core.gz**: `rootfs64.gz` is the base userspace filesystem (not the full initrd). It contains `tce-load`, `tce-ab`, `sh`, and the package manager — everything needed as a build environment.
- **Architecture of build tools**: `gcc`, `compiletc`, `bash`, `libisoburn` will all be 64-bit packages fetched from `17.x/x86_64/tcz/` automatically by `tce-load` running inside the 64-bit container.
- **EFI bootloader**: Already `super_grub2_disk_standalone_x86_64_efi_2.04s1.EFI` — no change.
- **isolinux in Stage 5**: `xorriso` assembles the ISO using `-b boot/isolinux/isolinux.bin`. TinyCorePure64 ships with the same isolinux structure — verify this holds after downloading the ISO.

## Acceptance Criteria

- [x] `build-base-image.sh` exists, is executable, and creates `tcl-core-x86_64:17.0` local Docker image
- [x] `docker build . -t tcbuild` succeeds using the new base image
- [ ] `docker run -it --rm -v pwd/output:/tmp/output tcbuild` completes all 6 stages without error
- [ ] Stage 4b correctly extracts `hid-apple.ko.gz` from the x86_64 `modules.gz`
- [ ] Kernel version string in the built image is `6.x-tinycore64` (current Pure64 version)
- [ ] Output ISO boots on a vintage iMac and reaches TDM
- [ ] `file output/boot-isos/Core-remastered.iso` reports x86-64 boot record (or equivalent)
- [x] README accurately describes the two-step build process

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `rootfs64.gz` cpio extraction missing files needed for build tools | Low | Test `tce-load` works inside the imported container before committing |
| `isolinux` path differs in Pure64 ISO | Low-Medium | Verify after downloading ISO; update `xorriso` args if needed |
| `cpupower.tcz` not available in x86_64 repo | Low | `tce-ab -s cpupower` inside container to confirm; have wget fallback |
| `hid-apple.ko.gz` path in x86_64 `modules.gz` differs | Low | Build script derives it dynamically from cpio listing — handles it |

## References

### Internal
- `Dockerfile:1–2` — FROM and TC_ISO_URL to change
- `files/build.sh:27` — URL validation regex (already compatible)
- `files/build.sh:71` — `TC_MODULES_URL` derivation (already compatible)
- `files/build.sh:94–95` — kernel version regex (already compatible)
- `files/supergrub/super_grub2_disk_standalone_x86_64_efi_2.04s1.EFI` — already x86_64

### External
- TinyCore Pure64 17.0 ISO: `http://tinycorelinux.net/17.x/x86_64/release/TinyCorePure64-17.0.iso`
- rootfs64.gz: `http://tinycorelinux.net/17.x/x86_64/release/distribution_files/rootfs64.gz`
- x86_64 package repo: `http://tinycorelinux.net/17.x/x86_64/tcz/`
