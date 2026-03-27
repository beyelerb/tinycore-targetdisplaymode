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


# acquire hid-apple module from TinyCore's modules archive
printf "## STAGE 4b: Acquire hid-apple module\n"

TC_MODULES_URL="$(dirname ${TC_ISO_URL})/distribution_files/modules.gz"
HID_EXTRACT_DIR=/tmp/hid-apple-extract
HID_PKG_DIR=/tmp/hid-apple-pkg

printf "Downloading modules archive from ${TC_MODULES_URL}...\n"
wget -q "${TC_MODULES_URL}" -O /tmp/modules.gz

# find the exact path of hid-apple.ko.gz within the cpio archive
HID_KO_PATH=$(zcat /tmp/modules.gz | cpio -t 2>/dev/null | grep "hid-apple\.ko\.gz$")
[ -n "${HID_KO_PATH}" ] || { printf "ERROR: hid-apple.ko.gz not found in modules archive\n"; exit 1; }
printf "Found: ${HID_KO_PATH}\n"

# extract just that file
mkdir -p ${HID_EXTRACT_DIR}
cd ${HID_EXTRACT_DIR}
zcat /tmp/modules.gz | cpio -idm "${HID_KO_PATH}" 2>/dev/null
cd ${build_dir}

# decompress .ko.gz -> .ko
gunzip "${HID_EXTRACT_DIR}/${HID_KO_PATH}"
HID_KO="${HID_EXTRACT_DIR}/${HID_KO_PATH%.gz}"

# derive kernel version from the archive path
TC_KVER=$(echo "${HID_KO_PATH}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-tinycore[0-9]*')
printf "TinyCore kernel version: ${TC_KVER}\n"

# package as hid-apple.tcz
mkdir -p ${HID_PKG_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid
cp "${HID_KO}" ${HID_PKG_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid/
mksquashfs ${HID_PKG_DIR} ${tinycore_dir}/Core-current/cde/optional/hid-apple.tcz
echo "hid-apple.tcz" >> ${tinycore_dir}/Core-current/cde/onboot.lst
printf "hid-apple.tcz packaged successfully\n"


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
