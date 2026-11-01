#!/usr/bin/env bash
#
# import-aosp-vendor-boot.sh — import the AOSP profile inputs into prebuilt/aosp/
#
# The AOSP profile is a separate vendor/recovery environment: an AOSP ROM ships
# its own vendor_boot with a platform ramdisk and bootconfig that do not match
# the HyperOS firmware. This extracts those two inputs from the ROM's own
# vendor_boot.img (64 MiB, header v4) so make-vendor-boot.sh can build the AOSP
# AVB-enabled/disabled pair without ever mixing the two platform layouts.
#
# Usage:
#   bash device/xiaomi/rodin/tools/import-aosp-vendor-boot.sh <vendor_boot.img>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${DEVICE_DIR}/prebuilt/aosp"
SOURCE="${1:-}"

[[ -n "${SOURCE}" ]] || { echo "usage: $0 <vendor_boot.img from the AOSP ROM>" >&2; exit 2; }
[[ -f "${SOURCE}" ]] || { echo "error: ${SOURCE} does not exist" >&2; exit 1; }

SIZE="$(stat -c %s "${SOURCE}")"
[[ "${SIZE}" -eq 67108864 ]] || \
    echo "warning: ${SOURCE} is ${SIZE} bytes, expected 67108864 (a full vendor_boot partition)" >&2

mkdir -p "${DEST}"

echo "== extracting the platform ramdisk"
python3 "${SCRIPT_DIR}/vendor_boot_tool.py" extract-ramdisk "${SOURCE}" \
    --type 1 --out "${DEST}/vendor_ramdisk00.tmp"

echo "== extracting the bootconfig"
python3 - "${SOURCE}" "${DEST}/bootconfig.tmp" "${SCRIPT_DIR}" <<'PY'
import sys
sys.path.insert(0, sys.argv[3])
from vendor_boot_tool import VendorBoot

image = VendorBoot(sys.argv[1])
if image.bootconfig_size:
    start = image.bootconfig_start
    open(sys.argv[2], "wb").write(image.raw[start:start + image.bootconfig_size])
    print("   bootconfig: %d bytes" % image.bootconfig_size)
else:
    open(sys.argv[2], "wb").close()
    print("   bootconfig: empty (the source image has none)")
PY

# Keep the source whole image too, so the AOSP profile can reuse its header,
# DTB and addresses instead of borrowing them from the HyperOS image.
cp -f "${SOURCE}" "${DEST}/vendor_boot_stock.img"
mv -f "${DEST}/vendor_ramdisk00.tmp" "${DEST}/vendor_ramdisk00"
mv -f "${DEST}/bootconfig.tmp" "${DEST}/bootconfig"

python3 "${SCRIPT_DIR}/vendor_boot_tool.py" info "${SOURCE}" >/dev/null

echo
echo "== imported into ${DEST#"${DEVICE_DIR}"/}"
sha256sum "${DEST}/vendor_ramdisk00" "${DEST}/bootconfig" "${DEST}/vendor_boot_stock.img"
echo
echo "Now build:  bash ${SCRIPT_DIR#"${DEVICE_DIR}/"} --profile all"
