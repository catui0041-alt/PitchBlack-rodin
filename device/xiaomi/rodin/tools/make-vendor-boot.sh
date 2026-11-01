#!/usr/bin/env bash
#
# make-vendor-boot.sh — assemble the flashable vendor_boot images for rodin.
#
# Run this after the Android build produced the recovery root. It produces the
# four release images this device needs:
#
#   vendor_boot-rodin-HOS-AVB-ENABLED.img
#   vendor_boot-rodin-HOS-AVB-DISABLED.img
#   vendor_boot-rodin-AOSP-AVB-ENABLED.img      (needs prebuilt/aosp/vendor_ramdisk00)
#   vendor_boot-rodin-AOSP-AVB-DISABLED.img     (same input)
#
# HOS is the stock HyperOS/OEM platform fragment (prebuilt/vendor_ramdisk00,
# i.e. the firmware the phone actually runs). AOSP is a separate profile with
# its own platform fragment, because an AOSP ROM ships a different platform
# ramdisk and bootconfig; import them with tools/import-aosp-vendor-boot.sh.
# The two PLATFORM layouts are never mixed.
#
# The "AVB DISABLED" images remove the avb/avb_keys options from the platform's
# first-stage fstab and repack it, so a ROM that does not run first-stage AVB
# can boot. Nothing else about the platform changes.
#
# The platform fragment is the firmware's own prebuilt/vendor_ramdisk00, kept
# verbatim and only recompressed (Zstandard level 19 instead of the LZ4 it ships
# with). It is the first-stage Android environment that both normal boot and
# recovery boot run against, so it is never pruned: doing that left the first
# stage without files the stock image expects and the device sat on the boot
# logo. The recovery fragment stays LZ4, the compression stock uses for it.
#
# Every profile packs: platform fragment + PBRP recovery fragment + stock DTB,
# and signs the result with an unsigned AVB hash footer -- the same shape the
# stock image ships (algorithm NONE). Signing with a test key is a different,
# unverified shape and is deliberately not done here.
#
# Usage (from the root of the PBRP source tree):
#   device/xiaomi/rodin/tools/make-vendor-boot.sh [--out-dir DIR]
#                                                 [--profile hos|aosp|all]
#                                                 [--no-avb]
#                                                 [--diagnostics]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOP_DIR="$(cd "${DEVICE_DIR}/../../.." && pwd)"

PARTITION_SIZE=67108864
# avbtool writes its hash footer into the last bytes of the partition, so the
# image handed to it must stop that far short of the end; signing pads the rest
# with zeros. Measured for a 4096-byte page: an image of the full 67108864
# bytes fails with "Image size ... exceeds maximum image size of 67039232".
AVB_FOOTER_RESERVE=69632
# The ramdisk table, page alignment and the bootconfig section sit between the
# last ramdisk byte and the end of the partition.
ALIGNMENT_RESERVE=$((16 * 1024))
# The practical ceiling for the two vendor ramdisks together. The stock image is
# 43.4 MiB; a 65.0 MiB snowflake bootlooped and a 59.4 MiB one hung on the boot
# logo. The proven layout for this board stays under 62 MB, with the platform
# recompressed as zstd and the recovery fragment kept LZ4.
COMBINED_RAMDISK_LIMIT=62000000
OUT="${OUT_DIR:-${TOP_DIR}/out}"
PRODUCT_OUT="${OUT}/target/product/rodin"
RECOVERY_ROOT="${PRODUCT_OUT}/recovery/root"
STOCK_IMAGE="${DEVICE_DIR}/prebuilt/vendor_boot_stock.img"
PLATFORM_RAMDISK="${DEVICE_DIR}/prebuilt/vendor_ramdisk00"
AOSP_STOCK_IMAGE="${DEVICE_DIR}/prebuilt/aosp/vendor_boot_stock.img"
AOSP_PLATFORM_RAMDISK="${DEVICE_DIR}/prebuilt/aosp/vendor_ramdisk00"
AOSP_BOOTCONFIG="${DEVICE_DIR}/prebuilt/aosp/bootconfig"
DTB="${DEVICE_DIR}/prebuilt/dtb/mt6899-rodin.dtb"
OUT_DIR_IMAGES="${PRODUCT_OUT}"
PROFILE=all
SIGN=1
DIAGNOSTICS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir) OUT_DIR_IMAGES="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --no-avb) SIGN=0; shift ;;
        --diagnostics) DIAGNOSTICS=1; shift ;;
        -h|--help) sed -n '3,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "${PROFILE}" in
    hos|aosp|all) ;;
    *) echo "error: --profile must be hos, aosp or all" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
[[ -d "${RECOVERY_ROOT}" ]] || die "no recovery root at ${RECOVERY_ROOT}. Build first:
  . build/envsetup.sh && lunch pb_rodin-eng && mka recoveryimage vendorbootimage"

for f in "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "${DTB}"; do
    [[ -f "${f}" ]] || die "missing ${f}. Run device/xiaomi/rodin/tools/extract-prebuilts.sh first."
done

WANT_HOS=0
WANT_AOSP=0
if [[ "${PROFILE}" == "hos" || "${PROFILE}" == "all" ]]; then WANT_HOS=1; fi
if [[ "${PROFILE}" == "aosp" || "${PROFILE}" == "all" ]]; then
    if [[ -f "${AOSP_PLATFORM_RAMDISK}" ]]; then
        WANT_AOSP=1
    elif [[ "${PROFILE}" == "aosp" ]]; then
        die "the AOSP profile needs ${AOSP_PLATFORM_RAMDISK}.
  Import it from the ROM's vendor_boot first:
  bash device/xiaomi/rodin/tools/import-aosp-vendor-boot.sh <vendor_boot.img>"
    else
        echo "== AOSP profile skipped: no ${AOSP_PLATFORM_RAMDISK#"${DEVICE_DIR}"/}"
        echo "   (import one with tools/import-aosp-vendor-boot.sh <vendor_boot.img>)"
    fi
fi
(( WANT_HOS || WANT_AOSP )) || die "nothing to build for --profile ${PROFILE}"

HOST_BIN="${OUT}/host/linux-x86/bin"
MKBOOTFS="${HOST_BIN}/mkbootfs"
[[ -x "${MKBOOTFS}" ]] || die "missing ${MKBOOTFS}; build the host tools first (mka mkbootfs)"
command -v lz4 >/dev/null 2>&1 || die "lz4 is required (apt install liblz4-tool)"
command -v zstd >/dev/null 2>&1 || die "zstd is required (apt install zstd)"
command -v cpio >/dev/null 2>&1 || die "cpio is required (apt install cpio)"
AVBTOOL="${HOST_BIN}/avbtool"
if [[ "${SIGN}" == "1" ]]; then
    [[ -x "${AVBTOOL}" ]] || die "missing ${AVBTOOL}; build avbtool first (mka avbtool)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --------------------------------------------------------- recovery ramdisk
# Paths PBRP ships that this recovery never needs. Removing them is what keeps
# platform+recovery under COMBINED_RAMDISK_LIMIT; the checks below stop the
# trim from ever taking something recovery runs.
RECOVERY_LANGUAGES_KEEP=en.xml
RECOVERY_TRIM_PATHS="
twres/fonts/DroidSansFallback.ttf
twres/fonts/NotoSansCJKjp-Regular.ttf
twres/fonts/RoboNoto-Medium.ttf
twres/fonts/OFL.txt
system/bin/magiskboot
system/bin/bash
system/bin/nano
system/lib64/libprotobuf-cpp-lite.so
vendor/lib64/libclang_rt.ubsan_standalone-aarch64-android.so
ramdisk-files.txt
ramdisk-files.sha256sum
"
RECOVERY_ESSENTIALS="
init
system/bin/init
system/bin/recovery
system/bin/adbd
system/bin/minadbd
system/bin/fastbootd
system/bin/keystore2
system/bin/linker64
system/lib64/libandroidicu.so
system/lib64/rodin-touch/libtensorflowlite_touch_c.so
system/etc/recovery.fstab
first_stage_ramdisk/fstab.emmc
"

# The platform fragment (the firmware's own vendor_ramdisk00) owns
# first_stage_ramdisk/fstab.mt6899. The recovery fragment is concatenated after
# it, so a copy in recovery/root replaces the firmware table -- including
# mi_ext, the overlay mounts and avb_keys -- for every boot that includes the
# recovery fragment. Stock ships only fstab.emmc here for the same reason.
FORBIDDEN_RECOVERY_PATHS="
first_stage_ramdisk/fstab.mt6899
"

echo "== trimming the recovery root"
for f in ${RECOVERY_TRIM_PATHS}; do rm -f "${RECOVERY_ROOT}/${f}"; done
if [[ -d "${RECOVERY_ROOT}/twres/languages" ]]; then
    find "${RECOVERY_ROOT}/twres/languages" -maxdepth 1 -type f -name '*.xml' \
        ! -name "${RECOVERY_LANGUAGES_KEEP}" -delete
fi
# ui.xml declares one <font> per language; a declaration whose file is gone is
# still opened by the theme loader, so drop the declarations with the fonts.
if [[ -f "${RECOVERY_ROOT}/twres/ui.xml" ]]; then
    sed -i -e '/DroidSansFallback\.ttf/d' -e '/NotoSansCJKjp-Regular\.ttf/d' \
        -e '/RoboNoto-Medium\.ttf/d' "${RECOVERY_ROOT}/twres/ui.xml"
fi
lost_trim=""
for f in ${RECOVERY_ESSENTIALS}; do
    # -L as well: /init is a symlink to /system/bin/init, and -e follows it out
    # of the ramdisk it was never meant to leave.
    [[ -e "${RECOVERY_ROOT}/${f}" || -L "${RECOVERY_ROOT}/${f}" ]] || lost_trim="${lost_trim} ${f}"
done
[[ -z "${lost_trim}" ]] || die "the recovery trim removed what recovery runs:${lost_trim}"

shadowed=""
for f in ${FORBIDDEN_RECOVERY_PATHS}; do
    [[ -e "${RECOVERY_ROOT}/${f}" ]] && shadowed="${shadowed} ${f}"
done
if [[ -n "${shadowed}" ]]; then
    if (( WANT_HOS )); then
        die "the recovery fragment ships what the HyperOS platform owns:${shadowed}
  The recovery cpio is concatenated after the platform cpio, so this file
  replaces the firmware's own first-stage table -- mi_ext, the overlay mounts
  and avb_keys -- on every boot that loads the fragment. Install it as
  first_stage_ramdisk/fstab.emmc instead (see device.mk)."
    else
        echo "== warning: the recovery fragment shadows${shadowed}; check the AOSP platform"
    fi
fi

MODULES=$(find "${RECOVERY_ROOT}/lib/modules" -maxdepth 1 -name '*.ko' 2>/dev/null | wc -l | tr -d ' ')
if (( MODULES > 7 )); then
    die "the recovery fragment carries ${MODULES} modules; expected at most 7"
fi

# Always pack recovery/root here, never the build's own fragment: the trim runs
# on this root, and the build's copy still carries everything that was cut.
BUILD_FRAGMENT="${PRODUCT_OUT}/obj/PACKAGING/vendor_ramdisk_fragments_intermediates/recovery.cpio.lz4"
if [[ -s "${BUILD_FRAGMENT}" ]]; then
    printf '   build fragment (untrimmed, not used): %s bytes\n' "$(stat -c %s "${BUILD_FRAGMENT}")"
fi

# lz4 legacy, exactly what the stock vendor_boot uses for this fragment. Only
# the platform fragment is recompressed (to zstd); the recovery fragment keeps
# the compression stock gives it.
pack_recovery() {
    "${MKBOOTFS}" "${RECOVERY_ROOT}" | lz4 -l -12 --favor-decSpeed > "$1"
    printf '   packed from %s: %s bytes\n' "${RECOVERY_ROOT#${PRODUCT_OUT}/}" "$(stat -c %s "$1")"
}

# strip_platform_owned <root> <platform blob>
# The two vendor ramdisks are one concatenated archive, so a path in the
# recovery fragment replaces the platform's copy of it. Stock recovery is
# built so that this never changes anything: it carries no system/bin/init at
# all, and its sepolicy and plat_file_contexts are byte-identical to the
# platform's. PBRP's fragment instead carries an Android 14 system/bin/init,
# sepolicy, contexts, prop.default and linker over an Android 15 platform.
# Removing the paths the platform owns makes the concatenation behave like
# stock for first-stage init and for every process that runs during a normal
# boot. Used by the diagnostics ladder, not by the release yet.
#
# The recovery payload itself is kept even where the platform ships a copy:
# the platform fragment is also where the stock recovery lives (it carries
# system/bin/recovery, fastbootd, adbd, toybox and the res/ images), so a blind
# "platform wins" rule would replace PBRP with the stock recovery. Nothing in
# this list is read during a normal boot: init only starts the recovery UI when
# misc says boot-recovery.
RECOVERY_OWNED_PATHS="
init.recovery.*
res/*
twres/*
sbin/*
system/bin/recovery
system/bin/adbd
system/bin/fastbootd
system/bin/toybox
system/bin/busybox
system/bin/keystore2
system/bin/e2fsdroid
system/bin/minadbd
system/bin/load-touch-modules.sh
system/etc/recovery.fstab
system/etc/twrp.flags
system/lib64/rodin-touch/*
"

recovery_owns() {
    local path="$1" pattern
    for pattern in ${RECOVERY_OWNED_PATHS}; do
        case "${path}" in
            ${pattern}) return 0 ;;
        esac
    done
    return 1
}

strip_platform_owned() {
    local root="$1" blob="$2" list="${WORK}/platform-members.txt" p n=0
    lz4 -d -f "${blob}" "${WORK}/platform-for-strip.cpio" >/dev/null
    cpio -it --quiet < "${WORK}/platform-for-strip.cpio" | sed 's#^\./##' > "${list}"
    while IFS= read -r p; do
        [[ -n "${p}" ]] || continue
        [[ -f "${root}/${p}" || -L "${root}/${p}" ]] || continue
        recovery_owns "${p}" && continue
        rm -f "${root}/${p}"
        n=$((n + 1))
    done < "${list}"
    printf '   dropped %s path(s) the platform fragment already provides\n' "${n}"
}

echo "== packing the recovery fragment"
pack_recovery "${WORK}/recovery.lz4"
RECOVERY_SIZE="$(stat -c %s "${WORK}/recovery.lz4")"

# ------------------------------------------------------- platform ramdisk
# The platform fragment is the firmware's own vendor_ramdisk00, kept byte for
# byte: it is the first-stage Android environment both normal boot and recovery
# boot run against -- init, linker64, libs, the VINTF manifests, the firmware
# fstab (with mi_ext and the 25 overlay mounts) and all 244 kernel modules. It
# used to be pruned here to make room, and that is what left the phone on the
# boot logo: the first stage then ran with files the stock image expects.
#
# The stock blob is LZ4 (29 MiB). Decompressing it and recompressing the same
# cpio with Zstandard level 19 gives ~17 MiB with no content change at all, and
# the rodin 6.6.x kernels unpack zstd initramfs (verified on the 6.6.118 image
# this device runs). That is what leaves room for a PBRP-sized recovery
# fragment. The recovery fragment stays LZ4, as stock does it.
PLATFORM_CPIO="${WORK}/platform.cpio"
PLATFORM_ROOT="${WORK}/platform-root"

unpack_platform() {
    lz4 -d -f "$1" "${PLATFORM_CPIO}" >/dev/null
    printf '   platform unpacked: %s bytes\n' "$(stat -c %s "${PLATFORM_CPIO}")"
}

# prepare_platform <blob> <keep|zstd|lz4> <strip-avb:0|1> <out>
prepare_platform() {
    local blob="$1" codec="$2" strip="$3" out="$4"

    if [[ "${codec}" == "keep" ]]; then
        (( strip == 0 )) || die "cannot strip the platform fstab from a platform fragment that is kept as shipped"
        cp -f "${blob}" "${out}"
        printf '   platform kept as shipped: %s bytes\n' "$(stat -c %s "${out}")"
        return 0
    fi

    unpack_platform "${blob}"

    if [[ "${strip}" == "1" ]]; then
        rm -rf "${PLATFORM_ROOT}"
        mkdir -p "${PLATFORM_ROOT}"
        ( cd "${PLATFORM_ROOT}" && \
          cpio -idm --quiet --no-absolute-filenames < "${PLATFORM_CPIO}" )
        strip_fstab_avb "${PLATFORM_ROOT}"
        assert_no_fstab_avb "${PLATFORM_ROOT}"
        "${MKBOOTFS}" "${PLATFORM_ROOT}" > "${PLATFORM_CPIO}.new"
        mv -f "${PLATFORM_CPIO}.new" "${PLATFORM_CPIO}"
        rm -rf "${PLATFORM_ROOT}"
    fi

    case "${codec}" in
        zstd)
            zstd -19 -T1 -q -f "${PLATFORM_CPIO}" -o "${out}"
            ;;
        lz4)
            lz4 -l -12 --favor-decSpeed < "${PLATFORM_CPIO}" > "${out}"
            ;;
        *)
            die "unknown platform codec: ${codec}"
            ;;
    esac
    printf '   platform %s: %s bytes\n' "${codec}" "$(stat -c %s "${out}")"
}

# --------------------------------------------------------- fstab AVB flags
# fs_mgr stops at the avb/avb_keys options in a first-stage fstab when AVB is
# disabled on the ROM. "AVB disabled" images must not ask for it at all.
strip_fstab_avb() {
    local root="$1" f count=0
    [[ -d "${root}/first_stage_ramdisk" ]] || return 0
    while IFS= read -r -d '' f; do
        awk '
            /^[[:space:]]*#/ || NF < 5 { print; next }
            {
                n = split($5, o, ",")
                rebuilt = ""
                for (i = 1; i <= n; i++) {
                    if (o[i] == "avb" || o[i] ~ /^avb=/ || o[i] ~ /^avb_keys=/) continue
                    rebuilt = (rebuilt == "" ? o[i] : rebuilt "," o[i])
                }
                $5 = (rebuilt == "" ? "defaults" : rebuilt)
                print
            }' "${f}" > "${f}.avb-tmp"
        mv -f "${f}.avb-tmp" "${f}"
        count=$((count + 1))
    done < <(find "${root}/first_stage_ramdisk" -type f -name 'fstab.*' -print0)
    echo "   stripped AVB options from ${count} first-stage fstab file(s) under ${root##*/}"
}

assert_no_fstab_avb() {
    local root="$1" f
    [[ -d "${root}/first_stage_ramdisk" ]] || return 0
    while IFS= read -r -d '' f; do
        if awk '/^[[:space:]]*#/ || NF < 5 { next }
                { n = split($5, o, ","); for (i = 1; i <= n; i++)
                      if (o[i] == "avb" || o[i] ~ /^avb=/ || o[i] ~ /^avb_keys=/) bad = 1 }
                END { exit bad ? 1 : 0 }' "${f}"; then
            :
        else
            die "first-stage AVB option survived in ${f}"
        fi
    done < <(find "${root}/first_stage_ramdisk" -type f -name 'fstab.*' -print0)
}

# An AOSP platform keeps its fstab below first_stage_ramdisk/system/etc, while
# HyperOS puts it directly in first_stage_ramdisk; the searches above cover both.

# --------------------------------------------------------------- one image
# build_image <out> <stock image> <platform fragment> <recovery lz4> <bootconfig|"">
build_image() {
    local out="$1" stock="$2" platform="$3" recovery="$4" bootconfig="$5"
    local combined budget content
    combined=$(( $(stat -c %s "${platform}") + $(stat -c %s "${recovery}") ))
    printf '   combined vendor ramdisk: %s bytes (limit %s)\n' "${combined}" "${COMBINED_RAMDISK_LIMIT}"
    (( combined < COMBINED_RAMDISK_LIMIT )) || die "platform + recovery ramdisks are ${combined} bytes; this board stops booting at ${COMBINED_RAMDISK_LIMIT}. Trim the recovery payload instead of shrinking the partition budget."

    budget=$((PARTITION_SIZE - $(stat -c %s "${platform}") - \
              $(stat -c %s "${DTB}") - AVB_FOOTER_RESERVE - ALIGNMENT_RESERVE))
    (( $(stat -c %s "${recovery}") <= budget )) || \
        die "the recovery fragment is $(stat -c %s "${recovery}") bytes but only ${budget} fit in vendor_boot"

    local -a args=(--platform "${platform}" --recovery "${recovery}" --dtb "${DTB}" \
                   --size "${PARTITION_SIZE}" --strip-vbmeta)
    if [[ "${SIGN}" == "1" ]]; then args+=(--no-pad); fi
    if [[ -n "${bootconfig}" ]]; then args+=(--bootconfig "${bootconfig}"); fi

    python3 "${SCRIPT_DIR}/vendor_boot_tool.py" rebuild "${stock}" "${WORK}/vendor_boot.img" \
        "${args[@]}"

    if [[ "${SIGN}" == "1" ]]; then
        content="$(stat -c %s "${WORK}/vendor_boot.img")"
        (( content <= PARTITION_SIZE - AVB_FOOTER_RESERVE )) || \
            die "the assembled image is ${content} bytes; avbtool needs ${AVB_FOOTER_RESERVE} bytes of room for its footer"
        # No --algorithm and no --key on purpose: the stock image is an unsigned
        # hash footer (algorithm NONE, 704-byte vbmeta) and this bootloader has
        # only ever accepted that shape. A test-key signature is a different
        # 2112-byte vbmeta with a public key the device does not know.
        #
        # The fingerprint property is the one the stock image carries. It is
        # read back out of the stock footer instead of from this build: the
        # PBRP tree builds as Redmi/rodin/rodin:...OS3.0.303.0.WOJCNXM (a
        # Chinese revision) while the platform fragment, the DTB and the
        # vbmeta chain on the device are the global OS3.0.302.0.WOJMIXM ones.
        # Copying the firmware's own value keeps an image from mixing regions,
        # which is the one thing that must never happen here.
        local fingerprint=""
        local -a avb_args=()
        fingerprint="$(python3 "${SCRIPT_DIR}/vendor_boot_tool.py" avb-prop \
            "${stock}" com.android.build.vendor_boot.fingerprint 2>/dev/null || true)"
        if [[ -z "${fingerprint}" && -s "${PRODUCT_OUT}/build_fingerprint.txt" ]]; then
            fingerprint="$(cat "${PRODUCT_OUT}/build_fingerprint.txt")"
        fi
        if [[ -n "${fingerprint}" ]]; then
            printf '   AVB fingerprint: %s\n' "${fingerprint}"
            avb_args+=(--prop "com.android.build.vendor_boot.fingerprint:${fingerprint}")
        fi
        "${AVBTOOL}" add_hash_footer \
            --image "${WORK}/vendor_boot.img" \
            --partition_name vendor_boot \
            --partition_size "${PARTITION_SIZE}" \
            "${avb_args[@]}"
    fi

    local size
    size="$(stat -c %s "${WORK}/vendor_boot.img")"
    [[ "${size}" -eq "${PARTITION_SIZE}" ]] || die "${out}: image is ${size} bytes, expected ${PARTITION_SIZE}"
    python3 "${SCRIPT_DIR}/vendor_boot_tool.py" info "${WORK}/vendor_boot.img" >/dev/null
    mkdir -p "$(dirname "${out}")"
    cp -f "${WORK}/vendor_boot.img" "${out}"
    ( cd "$(dirname "${out}")" && sha256sum "$(basename "${out}")" > "$(basename "${out}").sha256" )
    echo "   -> ${out} ($(stat -c %s "${out}") bytes)"
}

# ------------------------------------------------------------------ build
built=()
# build_profile <name> <stock> <platform blob> <aosp bootconfig|""> <suffix> <codec> <strip:0|1>
build_profile() {
    local name="$1" stock="$2" platform_blob="$3" aosp_bootconfig="$4" suffix="$5" codec="$6" strip="$7"
    echo "== ${name} (${suffix})"

    local platform="${WORK}/platform-${name}-${suffix}"
    prepare_platform "${platform_blob}" "${codec}" "${strip}" "${platform}"

    local bootconfig=""
    if [[ -n "${aosp_bootconfig}" ]]; then
        # The AOSP bootconfig is passed through untouched: it describes that
        # ROM's own cmdline and first-stage behaviour. HOS images carry none,
        # exactly like the stock HyperOS vendor_boot.
        bootconfig="${WORK}/bootconfig-${name}-${suffix}"
        cp -f "${aosp_bootconfig}" "${bootconfig}"
        printf '   vendor bootconfig: %s bytes (from the AOSP ROM)\n' \
            "$(stat -c %s "${bootconfig}")"
    fi

    local out="${OUT_DIR_IMAGES}/vendor_boot-rodin-${name}-${suffix}.img"
    build_image "${out}" "${stock}" "${platform}" "${WORK}/recovery-${suffix}.lz4" "${bootconfig}"
    built+=("${out}")
}

cp -f "${WORK}/recovery.lz4" "${WORK}/recovery-AVB-ENABLED.lz4"
# HOS: the firmware's platform fragment, recompressed as zstd. Kept as LZ4 it
# leaves no room for a PBRP-sized recovery fragment; zstd -19 turns the same
# 72,030,720-byte cpio into ~17 MB without changing one byte of content, and
# the 6.6.118 kernel this device runs unpacks a zstd initramfs.
if (( WANT_HOS )); then
    build_profile HOS "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "" "AVB-ENABLED" zstd 0
fi

# ------------------------------------------------ diagnostics for the hardware
# Five extra images, each differing from the release in one variable, so a hang
# on a real device can be attributed instead of guessed at:
#
#   DIAG-CONTROL-stock
#       the stock image, byte for byte. If this hangs, the flash command, the
#       slot or the partition name is wrong -- not the build.
#   DIAG-ZSTD-STOCKRECOVERY
#       our zstd platform fragment + the *stock* recovery fragment. If this
#       hangs, the platform recompression (or the vbmeta shape) is the cause.
#   DIAG-STOCKPLATFORM-PBRP
#       the stock LZ4 platform fragment kept untouched + the PBRP recovery
#       fragment recompressed with zstd. If this hangs, the PBRP fragment is
#       the cause; if it boots, the zstd platform is.
#   DIAG-STOCKPLATFORM-PBRP-CLEAN
#       the same pair, but every path the platform fragment already provides
#       (system/bin/init, sepolicy, the *_contexts files, ...) is removed from
#       the recovery fragment first, which is how the stock recovery fragment
#       is arranged. If PBRP hangs and this boots, the override is the cause.
#   DIAG-ZSTD-PBRP-CLEAN
#       the release shape with the cleaned fragment: zstd platform + cleaned
#       recovery. This is what a release would look like if the override is the
#       cause, so it is the fourth hardware test and the candidate to ship.
#
# The recovery fragment has to be repacked for the last three images because the
# stock platform (29.2 MB) plus the LZ4 recovery fragment (37.4 MB) no longer
# fits the 62 MB ceiling. Zstandard is supported by the same kernel
# (CONFIG_RD_ZSTD=y) and the recovery fragment is the only archive that is
# recompressed; the platform stays byte for byte as the firmware ships it.
if (( WANT_HOS && DIAGNOSTICS )); then
    echo "== diagnostics"
    control="${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-CONTROL-stock.img"
    cp -f "${STOCK_IMAGE}" "${control}"
    ( cd "${OUT_DIR_IMAGES}" && sha256sum "$(basename "${control}")" > "$(basename "${control}").sha256" )
    built+=("${control}")
    echo "   -> ${control} (copy of the stock image)"

    stock_recovery="${WORK}/stock-recovery.lz4"
    python3 "${SCRIPT_DIR}/vendor_boot_tool.py" extract-ramdisk "${STOCK_IMAGE}" \
        --type 2 --out "${stock_recovery}" >/dev/null
    build_image "${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-ZSTD-STOCKRECOVERY.img" \
        "${STOCK_IMAGE}" "${WORK}/platform-HOS-AVB-ENABLED" "${stock_recovery}" ""
    built+=("${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-ZSTD-STOCKRECOVERY.img")

    lz4 -d -f "${WORK}/recovery.lz4" "${WORK}/recovery.cpio" >/dev/null
    zstd -19 -T1 -q -f "${WORK}/recovery.cpio" -o "${WORK}/recovery.zst"
    build_image "${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-STOCKPLATFORM-PBRP.img" \
        "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "${WORK}/recovery.zst" ""
    built+=("${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-STOCKPLATFORM-PBRP.img")

    # Fourth image: same fragments, but the recovery fragment carries only what
    # the platform does not, so init, sepolicy and the contexts come from the
    # firmware exactly as they do with the stock recovery fragment. The trim
    # above still applies; this image only removes the override.
    rm -rf "${WORK}/recovery-clean"
    cp -a "${RECOVERY_ROOT}" "${WORK}/recovery-clean"
    strip_platform_owned "${WORK}/recovery-clean" "${PLATFORM_RAMDISK}"
    "${MKBOOTFS}" "${WORK}/recovery-clean" | zstd -19 -T1 -q -f -o "${WORK}/recovery-clean.zst"
    printf '   cleaned recovery packed: %s bytes\n' "$(stat -c %s "${WORK}/recovery-clean.zst")"
    build_image "${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-STOCKPLATFORM-PBRP-CLEAN.img" \
        "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "${WORK}/recovery-clean.zst" ""
    built+=("${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-STOCKPLATFORM-PBRP-CLEAN.img")

    # Fifth image: the shape the release would take if the override is the
    # cause -- our zstd platform plus the cleaned recovery fragment. Test it
    # only after images 2 and 4 have both booted.
    build_image "${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-ZSTD-PBRP-CLEAN.img" \
        "${STOCK_IMAGE}" "${WORK}/platform-HOS-AVB-ENABLED" "${WORK}/recovery-clean.zst" ""
    built+=("${OUT_DIR_IMAGES}/vendor_boot-rodin-DIAG-ZSTD-PBRP-CLEAN.img")
fi

if (( WANT_AOSP )); then
    stock="${STOCK_IMAGE}"
    if [[ -f "${AOSP_STOCK_IMAGE}" ]]; then stock="${AOSP_STOCK_IMAGE}"; fi
    aosp_bc=""
    if [[ -f "${AOSP_BOOTCONFIG}" ]]; then aosp_bc="${AOSP_BOOTCONFIG}"; fi
    # AOSP keeps its imported platform fragment exactly as it ships (LZ4): it
    # is small enough, and rewriting it would only add a variable.
    build_profile AOSP "${stock}" "${AOSP_PLATFORM_RAMDISK}" "${aosp_bc}" "AVB-ENABLED" keep 0
fi

# AVB-disabled pair. The only change is that avb/avb_keys disappear from the
# first-stage fstab -- in the platform fragment, which owns the firmware table,
# and in the recovery fragment. No bootconfig override is involved: the ROMs
# these images target simply do not run first-stage AVB, and lk still reports
# its own state.
echo "== building the AVB-disabled variants"
strip_fstab_avb "${RECOVERY_ROOT}"
assert_no_fstab_avb "${RECOVERY_ROOT}"
pack_recovery "${WORK}/recovery-AVB-DISABLED.lz4"

if (( WANT_HOS )); then
    build_profile HOS "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "" "AVB-DISABLED" zstd 1
fi
if (( WANT_AOSP )); then
    stock="${STOCK_IMAGE}"
    if [[ -f "${AOSP_STOCK_IMAGE}" ]]; then stock="${AOSP_STOCK_IMAGE}"; fi
    aosp_bc=""
    if [[ -f "${AOSP_BOOTCONFIG}" ]]; then aosp_bc="${AOSP_BOOTCONFIG}"; fi
    # An imported AOSP fragment is LZ4 and has to be repacked to edit its
    # fstab, so the disabled variant is recompressed with LZ4 as well.
    build_profile AOSP "${stock}" "${AOSP_PLATFORM_RAMDISK}" "${aosp_bc}" "AVB-DISABLED" lz4 1
fi

# Keep the historical artifact name pointing at the HOS AVB-enabled image, so
# existing docs, scripts and the workflow's single-image path keep working.
hos_default="${OUT_DIR_IMAGES}/vendor_boot-rodin-HOS-AVB-ENABLED.img"
OUT_IMAGE="${OUT_DIR_IMAGES}/vendor_boot-rodin.img"
if [[ -f "${hos_default}" ]]; then
    cp -f "${hos_default}" "${OUT_IMAGE}"
    ( cd "$(dirname "${OUT_IMAGE}")" && sha256sum "$(basename "${OUT_IMAGE}")" > "$(basename "${OUT_IMAGE}").sha256" )
fi

if (( ${#built[@]} )); then
    ( cd "${OUT_DIR_IMAGES}" && sha256sum $(for f in "${built[@]}"; do basename "$f"; done) \
        > RODIN-SHA256SUMS.txt )
fi

echo
echo "== done"
for f in "${built[@]}"; do
    printf '   %-56s %s bytes\n' "$(basename "$f")" "$(stat -c %s "$f")"
done
echo "   flash : fastboot flash vendor_boot_a <image>.img"
echo "           fastboot reboot recovery"
echo "   revert: fastboot flash vendor_boot_a ${STOCK_IMAGE}"
