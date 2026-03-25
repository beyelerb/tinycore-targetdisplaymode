#!/bin/bash

build_dir=/tmp/build
smcutil_dir=${build_dir}/smc_util
tinycore_dir=${build_dir}/tinycore
grub_dir=${build_dir}/grub
supergrub_dir=${build_dir}/supergrub
tdm_dir=${build_dir}/tdm
output_dir=/tmp/output


function my_trap_handler()
{
        MYSELF="$0"
        LASTLINE="$1"            # argument 1: last line of error occurence
        LASTERR="$2"             # argument 2: error code of last command
        echo "${MYSELF}: line ${LASTLINE}: exit status of last command: ${LASTERR}"

	# abort on failure
	exit 1
}

# divert errors to trap handler
trap 'my_trap_handler ${LINENO} ${$?}' ERR

# check if ISO source looks halfway legit, or bail out
echo ${TC_ISO_URL} | grep -Ee '^https?://(www\.)?tinycorelinux\.net/[0-9]+.*/.*\.iso' >/dev/null || { echo "Error: invalid ISO download source"; false; }


# build SMC utility from https://github.com/floe/smc_util
printf "## STAGE 1: build smc_util\n"
mkdir -p ${build_dir} 
git clone https://github.com/floe/smc_util.git ${smcutil_dir}
cd ${smcutil_dir}
cc -O2 -o SmcDumpKey SmcDumpKey.c -Wall


# fetch TinyCore ISO and extract it
printf "## STAGE 2: fetch TinyCore ISO\n"
mkdir -p ${tinycore_dir}
wget "${TC_ISO_URL}" -O ${tinycore_dir}/Core-current.iso
xorriso -osirrox on -indev ${tinycore_dir}/Core-current.iso -extract / ${tinycore_dir}/Core-current


# package it
printf "## STAGE 3: Make TDM tce package\n"
## NOTE: ${tdm_dir} and substructure is included when container is staged
## 	 the mkdir's below are thus NOT necessary
## mkdir -p ${tdm_dir}/usr/bin/ ${tdm_dir}/etc/init.d/services/
cp ${smcutil_dir}/SmcDumpKey ${tdm_dir}/usr/bin/ 
chmod 755 ${tdm_dir}/usr/bin/* ${tdm_dir}/etc/init.d/services/tdm ${tdm_dir}/usr/local/tce.installed/tdm

mkdir -p ${tinycore_dir}/Core-current/cde/optional
mksquashfs ${tdm_dir} ${tinycore_dir}/Core-current/cde/optional/tdm.tcz
echo tdm.tcz >> ${tinycore_dir}/Core-current/cde/onboot.lst


# get extra packages
printf "## STAGE 4: Get extra packages\n"
sudo -u tc tce-load -w cpupower
find /tmp/tce/optional -type f -exec cp {} ${tinycore_dir}/Core-current/cde/optional/ \;
find ${tinycore_dir}/Core-current/cde/optional/ -name cpupower.tcz | grep . || exit 1
cat >> ${tinycore_dir}/Core-current/cde/onboot.lst <<EOF
cpupower.tcz
EOF


# probe and acquire hid-apple module for proper Apple keyboard support
printf "## STAGE 4b: Acquire hid-apple module\n"

KERNEL_VER=$(uname -r)
HID_APPLE_FOUND=0

# Step 1: check if hid-apple is already available in the running kernel (built-in)
if modinfo hid-apple > /dev/null 2>&1; then
    printf "hid-apple already available in kernel ${KERNEL_VER} -- no package needed\n"
    HID_APPLE_FOUND=1
fi

# Step 2: try downloading a hid-apple package from TinyCore extension repository
if [ "${HID_APPLE_FOUND}" -eq 0 ]; then
    for pkg in hid-apple hid_apple hid-modules; do
        printf "Trying package: ${pkg}...\n"
        if sudo -u tc tce-load -w ${pkg} 2>/dev/null; then
            if find /tmp/tce/optional -name "${pkg}.tcz" | grep -q .; then
                cp /tmp/tce/optional/${pkg}.tcz \
                   ${tinycore_dir}/Core-current/cde/optional/
                echo "${pkg}.tcz" >> \
                   ${tinycore_dir}/Core-current/cde/onboot.lst
                HID_APPLE_FOUND=1
                printf "Found hid-apple via package: ${pkg}.tcz\n"
                break
            fi
        fi
    done
fi

# Step 3: fallback -- build a custom hid-apple.tcz by extracting from the kernel HID package
if [ "${HID_APPLE_FOUND}" -eq 0 ]; then
    printf "Attempting fallback: custom hid-apple.tcz from kernel HID package...\n"
    for hid_pkg in "kernel-hid" "kernel-hid-${KERNEL_VER}" "kernel-drivers-hid"; do
        printf "Trying HID package: ${hid_pkg}...\n"
        if sudo -u tc tce-load -w ${hid_pkg} 2>/dev/null && \
           find /tmp/tce/optional -name "${hid_pkg}.tcz" | grep -q .; then
            HID_EXTRACT_DIR=/tmp/hid-apple-extract
            mkdir -p ${HID_EXTRACT_DIR}
            if unsquashfs -dest ${HID_EXTRACT_DIR} \
               /tmp/tce/optional/${hid_pkg}.tcz \
               "*/hid-apple.ko*" 2>/dev/null; then
                if find ${HID_EXTRACT_DIR} -name "hid-apple.ko*" | grep -q .; then
                    mksquashfs ${HID_EXTRACT_DIR} \
                        ${tinycore_dir}/Core-current/cde/optional/hid-apple.tcz
                    echo "hid-apple.tcz" >> \
                        ${tinycore_dir}/Core-current/cde/onboot.lst
                    HID_APPLE_FOUND=1
                    printf "Built custom hid-apple.tcz from ${hid_pkg}\n"
                    break
                fi
            fi
            rm -rf ${HID_EXTRACT_DIR}
        fi
    done
fi

# fail hard if module could not be obtained by any path
if [ "${HID_APPLE_FOUND}" -eq 0 ]; then
    printf "ERROR: Could not obtain hid-apple module for kernel ${KERNEL_VER}\n"
    printf "  Tried: built-in probe, tce packages (hid-apple, hid_apple, hid-modules), kernel HID packages\n"
    exit 1
fi


# assemble the output files
printf "## STAGE 5: assemble output files\n"
printf ">> pre cleanup\n"
rm -rf ${output_dir}/*

printf ">> grub.cfg\n"
[ ! -d ${output_dir}/boot ] && mkdir -p ${output_dir}/boot
[ ! -d ${output_dir}/boot/grub ] && mkdir -p ${output_dir}/boot/grub
cp -rpv ${grub_dir}/* ${output_dir}/boot/grub


printf ">> EFI loader\n"
[ ! -d ${output_dir}/efi ] && mkdir -p ${output_dir}/efi
[ ! -d ${output_dir}/efi/boot ] && mkdir -p ${output_dir}/efi/boot
cp -rpv ${supergrub_dir}/super_grub2_disk_standalone_x86_64_efi_2.04s1.EFI ${output_dir}/efi/boot/bootX64.efi

printf ">> remastered TinyCore ISO\n"
[ ! -d ${output_dir}/boot-isos ] && mkdir -p ${output_dir}/boot-isos
xorriso -as mkisofs -l -J -r -V TC-custom -no-emul-boot \
	-boot-load-size 4 \
	-boot-info-table -b boot/isolinux/isolinux.bin \
	-c boot/isolinux/boot.cat -o ${output_dir}/boot-isos/Core-remastered.iso ${tinycore_dir}/Core-current

printf "## STAGE 6: process completed\n"
