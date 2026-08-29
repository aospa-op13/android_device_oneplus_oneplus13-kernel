#!/bin/bash
#
# Copyright (C) 2023 Paranoid Android
#
# SPDX-License-Identifier: Apache-2.0
#

set -e

### Setup
DUMP=
MY_DIR="${BASH_SOURCE%/*}"
SRC_ROOT="${MY_DIR}/../../.."
TMP_DIR=$(mktemp -d)
EXTRACT_KERNEL=true
declare -a MODULE_FOLDERS=("vendor_ramdisk" "vendor_dlkm" "system_dlkm")

trap 'rm -rf "${TMP_DIR}"' EXIT

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-kernel )
                EXTRACT_KERNEL=false
                ;;
        * )
                DUMP="${1}"
                ;;
    esac
    shift
done

[ -f "${MY_DIR}/Module.symvers" ] || touch "${MY_DIR}/Module.symvers"
[ -f "${MY_DIR}/System.map" ] || touch "${MY_DIR}/System.map"

# Check if dump is specified and exists
if [ -z "${DUMP}" ]; then
    echo "Please specify the dump!"
    exit 1
elif [ ! -d "${DUMP}" ]; then
    echo "Unable to find dump at ${DUMP}!"
    exit 1
fi

echo "Extracting files from ${DUMP}:"

### Helper: extract a raw partition image (sparse/erofs/ext4) into a dir
extract_img() {
    local IMG_SRC="${1}"
    local DEST_DIR="${2}"
    local RAW_IMG="${IMG_SRC}"

    mkdir -p "${DEST_DIR}"

    # Detect Android sparse image (magic: 0x3aff26ed, little-endian) and convert to raw
    if [ "$(xxd -p -l4 "${IMG_SRC}")" == "3aff26ed" ]; then
        command -v simg2img > /dev/null || { echo "  ! simg2img not found, cannot unsparse ${IMG_SRC}"; return 1; }
        RAW_IMG="${TMP_DIR}/$(basename "${IMG_SRC}").raw"
        simg2img "${IMG_SRC}" "${RAW_IMG}"
    fi

    # Detect erofs (magic: 0xE0F5E1E2 at offset 1024) vs assume ext4 otherwise
    if [ "$(xxd -p -s1024 -l4 "${RAW_IMG}")" == "e2e1f5e0" ]; then
        command -v fsck.erofs > /dev/null || { echo "  ! fsck.erofs not found, cannot extract ${IMG_SRC}"; return 1; }
        fsck.erofs --extract="${DEST_DIR}" "${RAW_IMG}" > /dev/null
    else
        command -v debugfs > /dev/null || { echo "  ! debugfs not found, cannot extract ${IMG_SRC}"; return 1; }
        debugfs -R "rdump / ${DEST_DIR}" "${RAW_IMG}" > /dev/null 2>&1
    fi
}

### Kernel
if ${EXTRACT_KERNEL}; then
    echo "Extracting boot image.."
    ${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py \
        --boot_img "${DUMP}/boot.img" \
        --out "${TMP_DIR}/boot.out" > /dev/null
    cp -f "${TMP_DIR}/boot.out/kernel" ${MY_DIR}/Image
    echo "  - Image"
fi

### DTBS
# Cleanup / Preparation
rm -rf "${MY_DIR}/dtbs"
mkdir "${MY_DIR}/dtbs"

echo "Extracting vendor_boot image..."
${SRC_ROOT}/system/tools/mkbootimg/unpack_bootimg.py \
    --boot_img "${DUMP}/vendor_boot.img" \
    --out "${TMP_DIR}/vendor_boot.out" > /dev/null

curl -sSL "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" > ${TMP_DIR}/extract_dtb.py

# Copy
python3 "${TMP_DIR}/extract_dtb.py" "${TMP_DIR}/vendor_boot.out/dtb" -o "${TMP_DIR}/dtbs" > /dev/null
find "${TMP_DIR}/dtbs" -type f -name "*.dtb" \
    -exec cp {} "${MY_DIR}/dtbs" \; \
    -exec printf "  - dtbs/" \; \
    -exec basename {} \;
[ -f "${DUMP}/dtbo.img" ] && cp -f "${DUMP}/dtbo.img" "${MY_DIR}/dtbs/dtbo.img" && echo "  - dtbs/dtbo.img"

### Modules
# Cleanup / Preparation
for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    rm -rf "${MY_DIR}/${MODULE_FOLDER}"
    mkdir "${MY_DIR}/${MODULE_FOLDER}"
done

# Copy
for MODULE_FOLDER in "${MODULE_FOLDERS[@]}"; do
    MODULE_SRC="${DUMP}/${MODULE_FOLDER}"

    if [ "${MODULE_FOLDER}" == "vendor_ramdisk" ]; then
        lz4 -qd "${TMP_DIR}/vendor_boot.out/vendor_ramdisk00" "${TMP_DIR}/vendor_ramdisk.cpio"
        7z x "${TMP_DIR}/vendor_ramdisk.cpio" -o"${TMP_DIR}/vendor_ramdisk" > /dev/null
        MODULE_SRC="${TMP_DIR}/vendor_ramdisk"
    elif [ ! -d "${MODULE_SRC}" ] && [ -f "${DUMP}/${MODULE_FOLDER}.img" ]; then
        echo "Extracting ${MODULE_FOLDER}.img..."
        MODULE_SRC="${TMP_DIR}/${MODULE_FOLDER}_extracted"
        extract_img "${DUMP}/${MODULE_FOLDER}.img" "${MODULE_SRC}" || continue
    fi

    if [ "${MODULE_FOLDER}" == "system_dlkm" ]; then
        cp -r "${MODULE_SRC}/flatten/." "${MY_DIR}/${MODULE_FOLDER}/flatten/"
        cp -r "${MODULE_SRC}/lib/." "${MY_DIR}/${MODULE_FOLDER}/lib/"
        find "${MODULE_SRC}/flatten/" "${MODULE_SRC}/lib/." -type f \
            -exec printf "  - ${MODULE_FOLDER}/" \; \
            -exec realpath --relative-to="${MODULE_SRC}" {} \;
    else
        find "${MODULE_SRC}/lib/modules" -type f \
            -exec cp {} "${MY_DIR}/${MODULE_FOLDER}/" \; \
            -exec printf "  - ${MODULE_FOLDER}/" \; \
            -exec basename {} \;
    fi
done
