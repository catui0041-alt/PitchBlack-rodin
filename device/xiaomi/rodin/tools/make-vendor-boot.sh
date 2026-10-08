#!/usr/bin/env bash
#
# make-vendor-boot.sh — assemble the flashable vendor_boot.img for rodin.
#
# Run this after the Android build produced the recovery root. It:
#   1. packs out/target/product/rodin/recovery/root into an lz4 legacy ramdisk
#      (the format the MTK bootloader and init expect, same as the stock image)
#   2. keeps the stock platform ramdisk and DTB, and replaces only the recovery
#      fragment, using tools/vendor_boot_tool.py
#   3. pads to the exact vendor_boot partition size and signs it with avbtool
#
# Usage (from the root of the PBRP source tree):
#   device/xiaomi/rodin/tools/make-vendor-boot.sh \
#       [--out out/target/product/rodin/vendor_boot-rodin.img] \
#       [--no-avb]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOP_DIR="$(cd "${DEVICE_DIR}/../../.." && pwd)"

PARTITION_SIZE=67108864
PRODUCT_OUT="${OUT_DIR:-${TOP_DIR}/out}/target/product/rodin"
RECOVERY_ROOT="${PRODUCT_OUT}/recovery/root"
STOCK_IMAGE="${DEVICE_DIR}/prebuilt/vendor_boot_stock.img"
PLATFORM_RAMDISK="${DEVICE_DIR}/prebuilt/vendor_ramdisk00"
DTB="${DEVICE_DIR}/prebuilt/dtb/mt6899-rodin.dtb"
OUT_IMAGE="${PRODUCT_OUT}/vendor_boot-rodin.img"
SIGN=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_IMAGE="$2"; shift 2 ;;
        --no-avb) SIGN=0; shift ;;
        -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ -d "${RECOVERY_ROOT}" ]] || die "no recovery root at ${RECOVERY_ROOT}. Build first:
  . build/envsetup.sh && lunch pb_rodin-eng && mka recoveryimage vendorbootimage"

for f in "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "${DTB}"; do
    [[ -f "${f}" ]] || die "missing ${f}. Run device/xiaomi/rodin/tools/extract-prebuilts.sh first."
done

HOST_BIN="${TOP_DIR}/out/host/linux-x86/bin"
MKBOOTFS="${HOST_BIN}/mkbootfs"
[[ -x "${MKBOOTFS}" ]] || die "missing ${MKBOOTFS}; build the host tools first (mka mkbootfs)"
command -v lz4 >/dev/null 2>&1 || die "lz4 is required (apt install liblz4-tool)"

# --------------------------------------------------------- recovery ramdisk
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
RAMDISK="${WORK}/recovery_ramdisk.lz4"

echo "== packing ${RECOVERY_ROOT}"
# lz4 legacy format, exactly what the stock vendor_boot and AOSP's ramdisk
# compression use.
"${MKBOOTFS}" "${RECOVERY_ROOT}" | lz4 -l -12 --favor-decSpeed > "${RAMDISK}"
RAMDISK_SIZE="$(stat -c %s "${RAMDISK}")"
printf '   recovery ramdisk: %s bytes\n' "${RAMDISK_SIZE}"

# ------------------------------------------------------- size budget guard
# vendor_boot already carries the stock platform ramdisk (about 29 MiB) and the
# wrapped DTB, so only ~36 MiB are left for this recovery ramdisk. Failing here
# with the reason beats watching the packer refuse the image later.
PLATFORM_SIZE="$(stat -c %s "${PLATFORM_RAMDISK}")"
DTB_SIZE="$(stat -c %s "${DTB}")"
RESERVE=$((64 * 1024))   # ramdisk table + vbmeta + alignment slack
BUDGET=$((PARTITION_SIZE - PLATFORM_SIZE - DTB_SIZE - 64 - RESERVE))
printf '   budget for the recovery ramdisk: %s bytes (%.1f MiB)\n' \
    "${BUDGET}" "$(awk -v b="${BUDGET}" 'BEGIN {print b / 1048576}')"
if (( RAMDISK_SIZE > BUDGET )); then
    cat >&2 <<EOF
error: the recovery ramdisk is $(awk -v s="${RAMDISK_SIZE}" 'BEGIN {printf "%.1f", s/1048576}') MiB but only $(awk -v b="${BUDGET}" 'BEGIN {printf "%.1f", b/1048576}') MiB fit in vendor_boot.

Shrink the ramdisk (these all worked for other ports of this board):
  * strip debug data:  TW_EXCLUDE_* / remove .gnu_debugdata from binaries in the ramdisk
  * drop unused languages and fonts from twres/ (keep one font)
  * build without lpdump: lpdump/lpdumpd pull in protobuf and snapshot libs
  * UPX the largest tools (or use whatever the PBRP branch offers)
EOF
    exit 1
fi
if (( BUDGET - RAMDISK_SIZE < 3 * 1024 * 1024 )); then
    echo "   warning: only $(awk -v b="$((BUDGET - RAMDISK_SIZE))" 'BEGIN {printf "%.1f", b/1048576}') MiB of headroom left for future changes"
fi

# ------------------------------------------------------------- repack
echo "== assembling vendor_boot"
python3 "${SCRIPT_DIR}/vendor_boot_tool.py" rebuild "${STOCK_IMAGE}" "${WORK}/vendor_boot.img" \
    --platform "${PLATFORM_RAMDISK}" \
    --recovery "${RAMDISK}" \
    --dtb "${DTB}" \
    --size "${PARTITION_SIZE}" \
    --strip-vbmeta

# ------------------------------------------------------------- signing
if [[ "${SIGN}" == "1" ]]; then
    AVBTOOL="${HOST_BIN}/avbtool"
    KEY="${TOP_DIR}/external/avb/test/data/testkey_rsa4096.pem"
    [[ -x "${AVBTOOL}" ]] || die "missing ${AVBTOOL}; build avbtool first (mka avbtool)"
    [[ -f "${KEY}" ]] || die "missing AVB test key ${KEY}"
    echo "== signing"
    "${AVBTOOL}" add_hash_footer \
        --image "${WORK}/vendor_boot.img" \
        --partition_name vendor_boot \
        --partition_size "${PARTITION_SIZE}" \
        --algorithm SHA256_RSA4096 \
        --key "${KEY}"
fi

# ------------------------------------------------------------- validate
SIZE="$(stat -c %s "${WORK}/vendor_boot.img")"
[[ "${SIZE}" -eq "${PARTITION_SIZE}" ]] || die "image is ${SIZE} bytes, expected ${PARTITION_SIZE}"
python3 "${SCRIPT_DIR}/vendor_boot_tool.py" info "${WORK}/vendor_boot.img" >/dev/null

mkdir -p "$(dirname "${OUT_IMAGE}")"
cp -f "${WORK}/vendor_boot.img" "${OUT_IMAGE}"
( cd "$(dirname "${OUT_IMAGE}")" && sha256sum "$(basename "${OUT_IMAGE}")" > "$(basename "${OUT_IMAGE}").sha256" )

echo
echo "== done"
echo "   image : ${OUT_IMAGE}"
echo "   size  : ${SIZE} bytes"
echo "   flash : fastboot flash vendor_boot ${OUT_IMAGE}"
echo "           fastboot reboot recovery"
