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


# package it
printf "## STAGE 3: Make TDM tce package\n"
## NOTE: ${tdm_dir} and substructure is included when container is staged
## 	 the mkdir's below are thus NOT necessary
## mkdir -p ${tdm_dir}/usr/bin/ ${tdm_dir}/etc/init.d/services/
cp ${smcutil_dir}/SmcDumpKey ${tdm_dir}/usr/bin/
chmod 755 ${tdm_dir}/usr/bin/* ${tdm_dir}/etc/init.d/services/tdm ${tdm_dir}/usr/local/tce.installed/tdm

mkdir -p ${tinycore_dir}/Core-current/cde/optional

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
if [ ! -f ${tdm_dir}/usr/local/etc/ssh/ssh_host_ed25519_key ]; then
    printf "WARNING: SSH host keys not found in ${tdm_dir}/usr/local/etc/ssh/\n"
    printf "  Run ./generate-ssh-keys.sh before building to get a stable host fingerprint.\n"
    printf "  Without host keys, openssh will generate ephemeral keys at each boot.\n"
fi

mksquashfs ${tdm_dir} ${tinycore_dir}/Core-current/cde/optional/tdm.tcz
echo tdm.tcz >> ${tinycore_dir}/Core-current/cde/onboot.lst


# acquire Apple HID modules from TinyCore's modules archive
printf "## STAGE 4b: Acquire Apple HID modules\n"

# x86_64 uses modules64.gz; x86 uses modules.gz
case "${TC_ISO_URL}" in
    *x86_64*) TC_MODULES_FILE="modules64.gz" ;;
    *)         TC_MODULES_FILE="modules.gz"   ;;
esac
TC_MODULES_URL="$(dirname ${TC_ISO_URL})/distribution_files/${TC_MODULES_FILE}"
HID_EXTRACT_DIR=/tmp/hid-apple-extract
HID_PKG_DIR=/tmp/hid-apple-pkg

printf "Downloading modules archive from ${TC_MODULES_URL}...\n"
wget -q "${TC_MODULES_URL}" -O /tmp/modules.gz

mkdir -p ${HID_EXTRACT_DIR}
mkdir -p ${HID_PKG_DIR}

# extract hid-apple.ko.gz and hid-appleir.ko.gz from the cpio archive
for module in hid-apple hid-appleir; do
    HID_KO_PATH=$(zcat /tmp/modules.gz | cpio -t 2>/dev/null | grep "${module}\.ko\.gz$")
    [ -n "${HID_KO_PATH}" ] || { printf "ERROR: ${module}.ko.gz not found in modules archive\n"; exit 1; }
    printf "Found: ${HID_KO_PATH}\n"

    cd ${HID_EXTRACT_DIR}
    zcat /tmp/modules.gz | cpio -idm "${HID_KO_PATH}" 2>/dev/null
    cd ${build_dir}

    gunzip "${HID_EXTRACT_DIR}/${HID_KO_PATH}"
done

# derive kernel version from the archive path (same for all modules)
TC_KVER=$(zcat /tmp/modules.gz | cpio -t 2>/dev/null | grep "hid-apple\.ko\.gz$" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-tinycore[0-9]*')
printf "TinyCore kernel version: ${TC_KVER}\n"

# package both modules into a single hid-apple.tcz
mkdir -p ${HID_PKG_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid
cp ${HID_EXTRACT_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid/hid-apple.ko \
   ${HID_PKG_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid/
cp ${HID_EXTRACT_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid/hid-appleir.ko \
   ${HID_PKG_DIR}/lib/modules/${TC_KVER}/kernel/drivers/hid/
# include modprobe.d config so fnmode=2 is set whenever hid-apple loads
mkdir -p ${HID_PKG_DIR}/etc/modprobe.d
echo "options hid-apple fnmode=2" > ${HID_PKG_DIR}/etc/modprobe.d/hid-apple.conf
mksquashfs ${HID_PKG_DIR} ${tinycore_dir}/Core-current/cde/optional/hid-apple.tcz
echo "hid-apple.tcz" >> ${tinycore_dir}/Core-current/cde/onboot.lst
printf "hid-apple.tcz packaged successfully (hid-apple + hid-appleir)\n"


# acquire openssh extension (and its openssl dependency) for remote access over ethernet
printf "## STAGE 4c: Acquire openssh\n"

TC_TCZ_URL="$(dirname $(dirname ${TC_ISO_URL}))/tcz"
OPENSSH_OK=1

for pkg in openssl openssh; do
    printf "Downloading ${pkg}.tcz...\n"
    if wget -q "${TC_TCZ_URL}/${pkg}.tcz" -O ${tinycore_dir}/Core-current/cde/optional/${pkg}.tcz; then
        echo "${pkg}.tcz" >> ${tinycore_dir}/Core-current/cde/onboot.lst
        printf "${pkg}.tcz added to image\n"
    else
        printf "WARNING: could not download ${pkg}.tcz — SSH will not be available at boot\n"
        OPENSSH_OK=0
        break
    fi
done

[ "${OPENSSH_OK}" -eq 1 ] && printf "openssh ready\n"


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
