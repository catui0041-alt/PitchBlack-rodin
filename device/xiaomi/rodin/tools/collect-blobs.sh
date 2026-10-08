#!/usr/bin/env bash
#
# collect-blobs.sh — fill proprietary/ with the vendor binaries recovery needs.
#
# The blob list is read straight out of proprietary/vendor-blobs.mk, so there is
# one source of truth: add a path there and this script knows about it.
#
# Modes
# -----
#   --check                     report which blobs are present and which are missing
#
#   --from-orangefox [--ref X]  copy them from the public OrangeFox port for rodin
#                               (clones into a cache dir, then copies the files)
#   --from-dump <dir>           copy them from a firmware dump already extracted
#                               on a PC (dir mirrors the ROM: dir/vendor, dir/odm, ...)
#   --modules                   extract recovery kernel modules from
#                               prebuilt/vendor_ramdisk00 into prebuilt/modules
#                               (only the ones recovery needs; ALL_MODULES=1 for all)
#
# Notes
# -----
# * rodin's own vendor_boot carries **no** kernel modules, so --modules usually
#   finds nothing; the touch modules live in the vendor_dlkm logical partition.
#   Use --from-dump with a dump that has vendor_dlkm extracted, or take them from
#   the OrangeFox port which publishes them for this board.
# * Nothing here is required for the build to succeed: vendor-blobs.mk skips
#   whatever is absent. The cost of a missing blob is a feature (FBE decrypt,
#   touch) that does not work in recovery.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BLOBS_MK="${DEVICE_DIR}/proprietary/vendor-blobs.mk"
PROPRIETARY="${DEVICE_DIR}/proprietary"
MODULE_DIR="${DEVICE_DIR}/prebuilt/modules"
CACHE_DIR="${DEVICE_DIR}/.collect-cache"
OF_REPO="${OF_REPO:-https://github.com/woshimaniubi8/orangefox_twrp_device_xiaomi_rodin}"

MODE=""
DUMP_DIR=""
OF_REF="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE=check; shift ;;
        --from-orangefox) MODE=orangefox; shift ;;
        --from-dump) MODE=dump; DUMP_DIR="${2:-}"; [[ -n "${DUMP_DIR}" ]] || { echo "error: --from-dump needs a directory" >&2; exit 2; }; shift 2 ;;
        --modules) MODE=modules; shift ;;
        --ref) OF_REF="${2:-main}"; shift 2 ;;
        -h|--help) sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "${MODE}" ]] || { echo "error: choose a mode (--check, --from-orangefox, --from-dump, --modules)" >&2; exit 2; }
[[ -f "${BLOBS_MK}" ]] || { echo "error: ${BLOBS_MK} not found" >&2; exit 1; }

# Read one "VAR := \ ... " block out of vendor-blobs.mk.
extract_var() {
    awk -v var="$1" '
        index($0, var " :=") > 0 {
            block = 1
            line = $0
            sub(/^.*:=/, "", line)
            gsub(/\\$/, "", line)
            if ($0 !~ /\\$/) block = 0
            print line
            next
        }
        block {
            line = $0
            gsub(/\\$/, "", line)
            if ($0 !~ /\\$/) block = 0
            print line
        }
    ' "${BLOBS_MK}" | awk 'NF' | sed 's/[[:space:]]*$//'
}

mapfile -t BLOB_PATHS < <(extract_var RODIN_BLOB_PATHS)
# The remap list is "source:destination"; only the source matters here.
mapfile -t BLOB_REMAP < <(extract_var RODIN_BLOB_REMAP | cut -d: -f1)

if [[ "${#BLOB_PATHS[@]}" -eq 0 ]]; then
    echo "error: could not parse RODIN_BLOB_PATHS from ${BLOBS_MK}" >&2
    exit 1
fi

all_blobs=("${BLOB_PATHS[@]}" "${BLOB_REMAP[@]}")

report() {
    local label="$1"
    shift
    local present=0 missing=0
    for rel in "$@"; do
        if [[ -s "${PROPRIETARY}/${rel}" ]]; then
            present=$((present + 1))
            [[ "${VERBOSE:-0}" == "1" ]] && printf '  ok      %s\n' "${rel}"
        else
            missing=$((missing + 1))
            printf '  MISSING %s\n' "${rel}"
        fi
    done
    printf '%s: %d present, %d missing (of %d)\n' "${label}" "${present}" "${missing}" "$((present + missing))"
    return 0
}

copy_into_proprietary() {
    local src_root="$1"
    local copied=0
    for rel in "${all_blobs[@]}"; do
        local src="${src_root}/${rel}"
        local dst="${PROPRIETARY}/${rel}"
        if [[ -s "${src}" ]]; then
            mkdir -p "$(dirname "${dst}")"
            cp -fp "${src}" "${dst}"
            copied=$((copied + 1))
        fi
    done
    echo "copied ${copied} file(s) from ${src_root}"
}

case "${MODE}" in
    check)
        echo "== blob status (looked up inside ${PROPRIETARY})"
        [[ "${VERBOSE:-0}" == "1" ]] || echo "   (set VERBOSE=1 to list the present ones too)"
        report "blobs" "${all_blobs[@]}"
        echo
        if compgen -G "${MODULE_DIR}/*.ko" > /dev/null; then
            echo "== recovery modules: $(ls -1 "${MODULE_DIR}"/*.ko | wc -l) in prebuilt/modules"
        else
            echo "== recovery modules: none yet (touch will not work in recovery)"
            echo "   try: tools/collect-blobs.sh --from-orangefox   (publishes them for this board)"
        fi
        ;;

    orangefox)
        command -v git >/dev/null || { echo "error: git is required" >&2; exit 1; }
        mkdir -p "$(dirname "${CACHE_DIR}")"
        if [[ -d "${CACHE_DIR}/.git" ]]; then
            echo "== refreshing ${CACHE_DIR}"
            git -C "${CACHE_DIR}" fetch --depth 1 origin "${OF_REF}"
            git -C "${CACHE_DIR}" checkout -q FETCH_HEAD
        else
            echo "== cloning ${OF_REPO} (depth 1, ${OF_REF})"
            rm -rf "${CACHE_DIR}"
            git clone --depth 1 --branch "${OF_REF}" "${OF_REPO}" "${CACHE_DIR}"
        fi
        if [[ ! -d "${CACHE_DIR}/proprietary" ]]; then
            echo "error: no proprietary/ in ${CACHE_DIR}; did the repo layout change?" >&2
            exit 1
        fi
        # Copy the whole staged tree: it already mirrors the ROM layout
        # (odm/, vendor/, touch/, ...), which is what vendor-blobs.mk expects.
        cp -a "${CACHE_DIR}/proprietary/." "${PROPRIETARY}/"
        echo "== copied $(find "${PROPRIETARY}" -type f | wc -l) file(s) into proprietary/"
        if compgen -G "${CACHE_DIR}/prebuilt/global/modules/*.ko" > /dev/null; then
            mkdir -p "${MODULE_DIR}"
            cp -fp "${CACHE_DIR}/prebuilt/global/modules/"*.ko "${MODULE_DIR}/"
            echo "== copied $(ls -1 "${MODULE_DIR}"/*.ko | wc -l) module(s) into prebuilt/modules/"
            echo "   note: those builds are patched for the Global firmware; if touch is dead"
            echo "         on a CN device, extract the modules from vendor_dlkm instead."
        fi
        echo
        echo "See docs/RODIN-NOTES.md for the attribution this implies."
        report "blobs" "${all_blobs[@]}"
        ;;

    dump)
        [[ -d "${DUMP_DIR}" ]] || { echo "error: ${DUMP_DIR} is not a directory" >&2; exit 1; }
        echo "== looking for blobs under ${DUMP_DIR}"
        copy_into_proprietary "${DUMP_DIR}"
        # vendor_dlkm is where the recovery modules actually live.
        for candidate in \
            "${DUMP_DIR}/vendor_dlkm/lib/modules" \
            "${DUMP_DIR}/vendor/lib/modules" \
            "${DUMP_DIR}/lib/modules"; do
            if compgen -G "${candidate}/*.ko" > /dev/null; then
                mkdir -p "${MODULE_DIR}"
                for mod in xiaomi_touch_rodin.ko focaltech_touch_rodin.ko \
                           goodix_core_rodin.ko nxp_i2c.ko p73.ko scp.ko si_haptic.ko; do
                    [[ -f "${candidate}/${mod}" ]] && cp -fp "${candidate}/${mod}" "${MODULE_DIR}/"
                done
                echo "== recovery modules found in ${candidate}"
                break
            fi
        done
        report "blobs" "${all_blobs[@]}"
        ;;

    modules)
        [[ -f "${DEVICE_DIR}/prebuilt/vendor_ramdisk00" ]] || {
            echo "error: prebuilt/vendor_ramdisk00 is missing; run extract-prebuilts.sh first" >&2
            exit 1
        }
        # Only the modules recovery actually needs: the platform ramdisk holds
        # ~244 modules (~30 MiB) and every one of them would have to fit inside
        # vendor_boot, whose budget for our recovery ramdisk is under 36 MiB.
        echo "== extracting recovery-relevant kernel modules from the stock platform ramdisk"
        if [[ "${ALL_MODULES:-0}" == "1" ]]; then
            echo "   (ALL_MODULES=1: extracting every module)"
            match='*.ko'
        else
            match='xiaomi_touch_rodin.ko,focaltech_touch_rodin.ko,goodix_core_rodin.ko,nxp_i2c.ko,p73.ko,scp.ko,si_haptic.ko'
        fi
        python3 "${SCRIPT_DIR}/vendor_ramdisk.py" extract \
            "${DEVICE_DIR}/prebuilt/vendor_ramdisk00" \
            --to "${MODULE_DIR}" --match "${match}" --report missing
        if ! compgen -G "${MODULE_DIR}/*.ko" > /dev/null; then
            echo
            echo "No modules in this ramdisk. That matches what the stock image on this"
            echo "device contains: the recovery-only modules live in the vendor_dlkm"
            echo "logical partition (inside super.img), not in vendor_boot. Extract them"
            echo "with lpunpack on a PC, then rerun:"
            echo "  tools/collect-blobs.sh --from-dump <extracted-super-dir>"
        fi
        ;;
esac
