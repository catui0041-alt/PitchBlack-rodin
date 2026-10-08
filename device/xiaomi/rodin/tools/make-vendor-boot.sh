#!/usr/bin/env bash
#
# make-vendor-boot.sh — assemble the flashable vendor_boot.img for rodin.
#
# Run this after the Android build produced the recovery root. It:
#   1. takes the recovery fragment the build already produced
#      (obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4),
#      falling back to packing recovery/root itself when that file is missing
#   2. prunes the stock platform ramdisk. It ships a complete stock-recovery
#      userspace (system/bin/recovery, adbd, fastbootd, update_engine_sideload,
#      toybox, res/ …) that the recovery fragment replaces anyway, and a device
#      VINTF fragment under /system that hwservicemanager reads as a framework
#      fragment, which keeps Keystore2 — and therefore metadata decryption —
#      from ever starting. Dropping the first is what makes a PBRP-sized
#      fragment fit at all; escaping the second is what makes decryption work.
#   3. assembles the pruned platform ramdisk, the recovery fragment and the
#      stock DTB with tools/vendor_boot_tool.py, pads to the exact vendor_boot
#      partition size and signs the result with avbtool
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
command -v cpio >/dev/null 2>&1 || die "cpio is required (apt install cpio)"

# --------------------------------------------------------- recovery ramdisk
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
RAMDISK="${WORK}/recovery_ramdisk.lz4"

# Prefer the fragment the build itself produced: it is the exact payload AOSP's
# own vendorbootimage would flash, and mkbootfs run by the build dedups against
# $(TARGET_OUT), which is worth several MiB. Pack recovery/root as well so the
# two can be compared instead of guessed at, and keep whichever is smaller.
BUILD_FRAGMENT="${PRODUCT_OUT}/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
echo "== packing the recovery fragment"
# lz4 legacy format, exactly what the stock vendor_boot and AOSP's ramdisk
# compression use.
"${MKBOOTFS}" "${RECOVERY_ROOT}" | lz4 -l -12 --favor-decSpeed > "${RAMDISK}"
printf '   packed from %s: %s bytes\n' "${RECOVERY_ROOT#${PRODUCT_OUT}/}" "$(stat -c %s "${RAMDISK}")"
if [[ -s "${BUILD_FRAGMENT}" ]]; then
    printf '   fragment from the build: %s bytes\n' "$(stat -c %s "${BUILD_FRAGMENT}")"
    if (( $(stat -c %s "${BUILD_FRAGMENT}") < $(stat -c %s "${RAMDISK}") )); then
        cp -f "${BUILD_FRAGMENT}" "${RAMDISK}"
        echo "   using the smaller one: the build's fragment"
    else
        echo "   using the smaller one: the one packed here"
    fi
else
    echo "   warning: ${BUILD_FRAGMENT#${PRODUCT_OUT}/} is missing, keeping the packed copy"
fi
RAMDISK_SIZE="$(stat -c %s "${RAMDISK}")"

# -------------------------------------- platform ramdisk: prune and repack
# The stock platform fragment is 29 MiB of which 13 MiB unpacked is a complete
# stock-recovery userspace that the recovery fragment replaces: system/bin/
# recovery, adbd, fastbootd, update_engine_sideload, toybox, toolbox, sh, logd,
# servicemanager, res/ … Normal Android boot never reads any of it once /system
# is mounted, and dropping it frees about 5.5 MiB of the image — the difference
# between a PBRP-sized recovery fragment fitting in this partition or not.
#
# The one file that must not just disappear is the MediaTek AIDL BootControl
# manifest: it is a *device* manifest, and a device manifest below /system is
# parsed as a framework fragment, so hwservicemanager never brings up Keystore2
# and recovery waits forever for metadata decryption. It is moved to vendor/
# (where it belongs) instead of being deleted.
#
# Everything first-stage init and normal boot need is kept and asserted after
# the prune, so a wrong entry here fails the build instead of the phone.
PLATFORM_UNPACKED="${WORK}/platform.cpio"
PLATFORM_ROOT="${WORK}/platform-root"
PRUNED_PLATFORM="${WORK}/platform-pruned.cpio.lz4"
PLATFORM_BOOTCONTROL_MANIFEST=system/etc/vintf/manifest/android.hardware.boot-service.mtk.xml
PLATFORM_PRUNE_PATHS="
res
miui.factoryreset.rc
system/bin/adbd
system/bin/fastbootd
system/bin/logcat
system/bin/logd
system/bin/recovery
system/bin/servicemanager
system/bin/sh
system/bin/toolbox
system/bin/toybox
system/bin/update_engine_sideload
system/bin/hw/android.hardware.health-service.example_recovery
system/etc/init/android.hardware.health-service.example_recovery.rc
system/etc/init/recovery-persist.rc
system/etc/init/recovery-refresh.rc
system/etc/init/servicemanager.recovery.rc
system/etc/recovery.fstab
system/etc/security/otacerts.zip
system/etc/init/android.hardware.boot-service.mtk_recovery.rc
system/etc/vintf/manifest/android.hardware.health-service.example.xml
system/lib64/librecovery_ui.so
"
PLATFORM_ESSENTIALS="
system/bin/init
system/bin/linker64
system/lib64/libc.so
system/lib64/libmtk_bsg.so
system/bin/hw/android.hardware.boot-service.mtk_recovery
first_stage_ramdisk/fstab.mt6899
lib/modules/modules.load
"
EXPECTED_PLATFORM_MODULES=244

echo "== pruning the stock platform ramdisk"
lz4 -d -f "${PLATFORM_RAMDISK}" "${PLATFORM_UNPACKED}"
mkdir -p "${PLATFORM_ROOT}"
( cd "${PLATFORM_ROOT}" && cpio -idm --quiet --no-absolute-filenames < "${PLATFORM_UNPACKED}" )
[[ -f "${PLATFORM_ROOT}/${PLATFORM_BOOTCONTROL_MANIFEST}" ]] || \
    die "the stock platform ramdisk no longer carries ${PLATFORM_BOOTCONTROL_MANIFEST}"
mkdir -p "${PLATFORM_ROOT}/vendor/etc/vintf/manifest"
mv -f "${PLATFORM_ROOT}/${PLATFORM_BOOTCONTROL_MANIFEST}" \
      "${PLATFORM_ROOT}/vendor/etc/vintf/manifest/"
for f in ${PLATFORM_PRUNE_PATHS}; do rm -rf "${PLATFORM_ROOT}/${f}"; done
lost=""
for f in ${PLATFORM_ESSENTIALS}; do [[ -e "${PLATFORM_ROOT}/${f}" ]] || lost="${lost} ${f}"; done
[[ -z "${lost}" ]] || die "pruning the platform removed what boot needs:${lost}"
if grep -rqs 'type="device"' "${PLATFORM_ROOT}/system/etc/vintf/manifest" 2>/dev/null; then
    die "a device VINTF fragment still sits under /system after pruning; hwservicemanager would read it as a framework fragment and Keystore2 would never start"
fi
modules="$(find "${PLATFORM_ROOT}/lib/modules" -maxdepth 1 -name '*.ko' | wc -l | tr -d ' ')"
[[ "${modules}" -eq "${EXPECTED_PLATFORM_MODULES}" ]] || \
    die "the pruned platform carries ${modules} kernel modules, expected ${EXPECTED_PLATFORM_MODULES}"
# -d lets mkbootfs dedup against the built system dir, the way the build runs it
if [[ -d "${PRODUCT_OUT}/system" ]]; then
    "${MKBOOTFS}" -d "${PRODUCT_OUT}/system" "${PLATFORM_ROOT}" > "${WORK}/platform-pruned.cpio"
else
    "${MKBOOTFS}" "${PLATFORM_ROOT}" > "${WORK}/platform-pruned.cpio"
fi
lz4 -l -12 --favor-decSpeed < "${WORK}/platform-pruned.cpio" > "${PRUNED_PLATFORM}"

# ------------------------------------------------------- size budget guard
PLATFORM_STOCK_SIZE="$(stat -c %s "${PLATFORM_RAMDISK}")"
PLATFORM_SIZE="$(stat -c %s "${PRUNED_PLATFORM}")"
DTB_SIZE="$(stat -c %s "${DTB}")"
RESERVE=$((64 * 1024))   # ramdisk table + vbmeta + alignment slack
BUDGET=$((PARTITION_SIZE - PLATFORM_SIZE - DTB_SIZE - 64 - RESERVE))
printf '   platform ramdisk: %s -> %s bytes, %s modules kept\n' \
    "${PLATFORM_STOCK_SIZE}" "${PLATFORM_SIZE}" "${modules}"
printf '   budget for the recovery fragment: %s bytes (%.1f MiB)\n' \
    "${BUDGET}" "$(awk -v b="${BUDGET}" 'BEGIN {print b / 1048576}')"
if (( RAMDISK_SIZE > BUDGET )); then
    {
        cat <<EOF
error: the recovery fragment is $(awk -v s="${RAMDISK_SIZE}" 'BEGIN {printf "%.1f", s/1048576}') MiB but only $(awk -v b="${BUDGET}" 'BEGIN {printf "%.1f", b/1048576}') MiB fit in vendor_boot
       (platform ${PLATFORM_STOCK_SIZE} bytes stock, ${PLATFORM_SIZE} pruned; over by $(awk -v o="$((RAMDISK_SIZE - BUDGET))" 'BEGIN {printf "%.2f", o/1048576}') MiB).

The largest files in the recovery root are the ones to trim:
EOF
        find "${RECOVERY_ROOT}" -type f -printf '%s\t%p\n' | sort -rn | head -20 |
            awk '{printf "  %8.2f MiB  %s\n", $1/1048576, $2}'
        cat <<'EOF'

Knobs that shrink the recovery ramdisk on this board:
  * TW_EXCLUDE_TWRPAPP / TW_EXCLUDE_SUPERSU in BoardConfig.mk
  * drop unused languages and fonts from twres/ (keep one font)
  * build without lpdump: lpdump/lpdumpd pull in protobuf and snapshot libs
EOF
    } >&2
    exit 1
fi
if (( BUDGET - RAMDISK_SIZE < 3 * 1024 * 1024 )); then
    echo "   warning: only $(awk -v b="$((BUDGET - RAMDISK_SIZE))" 'BEGIN {printf "%.1f", b/1048576}') MiB of headroom left for future changes"
fi

# ------------------------------------------------------------- repack
echo "== assembling vendor_boot"
python3 "${SCRIPT_DIR}/vendor_boot_tool.py" rebuild "${STOCK_IMAGE}" "${WORK}/vendor_boot.img" \
    --platform "${PRUNED_PLATFORM}" \
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
