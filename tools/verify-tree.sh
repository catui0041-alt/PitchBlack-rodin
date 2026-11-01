#!/usr/bin/env bash
#
# verify-tree.sh — checks that this device tree is internally consistent.
#
# It does NOT build PBRP (that needs the full source tree); it verifies the
# things that are cheap to get wrong and expensive to discover during a build:
#   * every file the device tree references really exists
#   * the shell/python tools parse
#   * the wildcard logic in device.mk/proprietary picks files up when present
#   * the CI workflow is valid YAML
#   * files that get executed carry the executable bit in the commit
#   * the image handed to avbtool leaves room for the AVB hash footer, and is
#     verified from a directory where avbtool resolves it to itself
#
# Run from anywhere:  tools/verify-tree.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_DIR="${REPO_DIR}/device/xiaomi/rodin"
FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok    %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$1"; }
note() { printf '\n== %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }

note "required files"
required=(
    "device/xiaomi/rodin/BoardConfig.mk"
    "device/xiaomi/rodin/device.mk"
    "device/xiaomi/rodin/pb_rodin.mk"
    "device/xiaomi/rodin/AndroidProducts.mk"
    "device/xiaomi/rodin/vendorsetup.sh"
    "device/xiaomi/rodin/recovery/root/system/etc/recovery.fstab"
    "device/xiaomi/rodin/recovery/root/system/etc/twrp.flags"
    "device/xiaomi/rodin/recovery/root/init.recovery.mt6899.rc"
    "device/xiaomi/rodin/recovery/root/init.recovery.hardware.rc"
    "device/xiaomi/rodin/tools/vendor_ramdisk.py"
    "device/xiaomi/rodin/tools/collect-blobs.sh"
    "device/xiaomi/rodin/recovery/root/first_stage_ramdisk/fstab.mt6899"
    "device/xiaomi/rodin/proprietary/vendor-blobs.mk"
    "device/xiaomi/rodin/tools/extract-prebuilts.sh"
    "device/xiaomi/rodin/tools/vendor_boot_tool.py"
    "device/xiaomi/rodin/tools/make-vendor-boot.sh"
    "device/xiaomi/rodin/prebuilt/README.md"
    "tools/setup-swap.sh"
    ".github/workflows/pbrp-build.yml"
    "README.md"
    "docs/RODIN-NOTES.md"
    "docs/BUILD-AND-FLASH.md"
)
for f in "${required[@]}"; do
    if [[ -e "${REPO_DIR}/${f}" ]]; then pass "$f"; else fail "missing $f"; fi
done

note "shell syntax"
while IFS= read -r script; do
    if bash -n "${script}" 2>/dev/null; then
        pass "bash -n ${script#${REPO_DIR}/}"
    else
        fail "bash -n $(basename "${script}")"
        bash -n "${script}" || true
    fi
done < <(find "${REPO_DIR}/device" "${REPO_DIR}/tools" -name '*.sh' -type f)

note "python syntax"
while IFS= read -r py; do
    if python3 -m py_compile "${py}" 2>/dev/null; then
        pass "py_compile ${py#${REPO_DIR}/}"
    else
        fail "py_compile ${py#${REPO_DIR}/}"
    fi
done < <(find "${REPO_DIR}/device" "${REPO_DIR}/tools" -name '*.py' -type f)

note "make logic: does device.mk reference real files?"
HARNESS="$(mktemp -d)"
trap 'rm -rf "${HARNESS}"' EXIT
cat > "${HARNESS}/harness.mk" <<MAKE
DEVICE_PATH := ${DEVICE_DIR}
PRODUCT_COPY_FILES :=
PRODUCT_PACKAGES :=
PRODUCT_PACKAGES_DEBUG :=
include \$(DEVICE_PATH)/device.mk
all:
	@echo \$(foreach c,\$(PRODUCT_COPY_FILES),\$(firstword \$(subst :, ,\$(c))))
dests:
	@echo \$(foreach c,\$(PRODUCT_COPY_FILES),\$(lastword \$(subst :, ,\$(c))))
MAKE

if ! command -v make >/dev/null 2>&1; then
    fail "make is not installed, cannot check device.mk copy rules"
else
    sources="$(make -s -f "${HARNESS}/harness.mk" all 2>/dev/null)"
    if [[ -z "${sources}" ]]; then
        fail "device.mk produced no PRODUCT_COPY_FILES at all"
    else
        missing=0
        dirs=0
        count=0
        for src in ${sources}; do
            count=$((count + 1))
            if [[ ! -e "${src}" ]]; then
                fail "copy rule points at a missing file: ${src}"
                missing=1
            elif [[ -d "${src}" ]]; then
                # A directory source generates `rm -f <dest> && cp <dir> <dest>`,
                # and rm cannot unlink a directory: the build dies with
                # "rm: <dest>: Is a directory". Expand directories into one rule
                # per file instead.
                fail "copy rule points at a directory, not a file: ${src}"
                dirs=1
            fi
        done
        [[ "${missing}" -eq 0 && "${dirs}" -eq 0 ]] && pass "all ${count} PRODUCT_COPY_FILES sources are regular files"

        # The ramdisk root is not a blank slate: system/core/rootdir lays down
        # symlinks first (odm/bin -> /vendor/odm/bin, bin -> /system/bin, …) and
        # the recovery root is then produced by rsyncing that tree over it. A
        # real file at one of those destinations makes rsync refuse to replace
        # the directory with the symlink, which killed a build at 99%.
        # /vendor, /product and /system_ext are symlinks only when the tree does
        # not build those images itself, so those three depend on BoardConfig.
        symlinked="bin/ etc/ cache/ odm/ sdcard/ vendor_dlkm/ odm_dlkm/ d/"
        for img_var in BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE:vendor \
                       BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE:product \
                       BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE:system_ext; do
            var="${img_var%%:*}"
            dir="${img_var##*:}"
            grep -qE "^[[:space:]]*${var}[[:space:]]*:=" "${DEVICE_DIR}/BoardConfig.mk" || symlinked="${symlinked} ${dir}/"
        done
        dests="$(make -s -f "${HARNESS}/harness.mk" dests 2>/dev/null)"
        bad_dest=""
        for d in ${dests}; do
            for p in ${symlinked}; do
                case "${d}" in
                    "recovery/root/${p}"*) bad_dest="${bad_dest} ${d}" ;;
                esac
            done
        done
        if [[ -z "${bad_dest}" ]]; then
            pass "no copy rule writes under a directory the ramdisk makes a symlink"
        else
            fail "copy rule(s) write under a ramdisk symlink:${bad_dest}"
        fi

        # The .ta files are the reason the directory rule above exists: when the
        # directory is populated every file in it must be copied individually.
        ta_dir="${DEVICE_DIR}/proprietary/vendor/mitee/ta"
        ta_count=$(find "${ta_dir}" -maxdepth 1 -name '*.ta' -type f 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${ta_count}" -gt 0 ]]; then
            # The harness echoes every source on a single line, so count
            # occurrences rather than lines.
            copied=$(grep -o "vendor/mitee/ta/" <<< "${sources}" | wc -l | tr -d ' ')
            if [[ "${copied}" -eq "${ta_count}" ]]; then
                pass "each of the ${ta_count} TEE trusted applications is copied individually"
            else
                fail "${ta_count} .ta files present but ${copied} copy rules reference them"
            fi
        else
            echo "  skip  no .ta files collected yet (proprietary/vendor/mitee/ta is empty)"
        fi
    fi

    # The blob/module rules are wildcard-guarded: create a dummy of each and
    # confirm it shows up, then remove it. Anything real at those paths is
    # backed up first — once the blob set is populated these are real files and
    # a test must never clobber them.
    dummy_blob="${DEVICE_DIR}/proprietary/vendor/bin/tee-supplicant"
    dummy_module="${DEVICE_DIR}/prebuilt/modules/verify-dummy.ko"
    blob_backup=""
    module_backup=""
    if [[ -e "${dummy_blob}" ]]; then blob_backup="${HARNESS}/blob.bak"; cp -p "${dummy_blob}" "${blob_backup}"; fi
    if [[ -e "${dummy_module}" ]]; then module_backup="${HARNESS}/module.bak"; cp -p "${dummy_module}" "${module_backup}"; fi
    mkdir -p "$(dirname "${dummy_blob}")" "$(dirname "${dummy_module}")"
    : > "${dummy_blob}"
    : > "${dummy_module}"
    with_dummies="$(make -s -f "${HARNESS}/harness.mk" all 2>/dev/null)"
    if grep -q "tee-supplicant" <<< "${with_dummies}"; then
        pass "wildcard blob rule picks up a present blob"
    else
        fail "a present blob was not copied (wildcard rule broken)"
    fi
    if grep -q "verify-dummy.ko" <<< "${with_dummies}"; then
        pass "wildcard module rule picks up a present module"
    else
        fail "a present module was not packaged (wildcard rule broken)"
    fi
    if grep -q "load-touch-modules.sh" <<< "${with_dummies}"; then
        pass "module loader script is packaged with the modules"
    else
        fail "module loader script is not packaged when modules exist"
    fi
    rm -f "${dummy_blob}" "${dummy_module}"
    if [[ -n "${blob_backup}" ]]; then cp -p "${blob_backup}" "${dummy_blob}"; fi
    if [[ -n "${module_backup}" ]]; then cp -p "${module_backup}" "${dummy_module}"; fi
    without_dummies="$(make -s -f "${HARNESS}/harness.mk" all 2>/dev/null)"
    if [[ "${without_dummies}" == "${sources}" ]]; then
        pass "removing the dummies restores the original copy list"
    else
        fail "copy list changed after removing dummy files"
    fi
fi

note "workflow YAML"
workflow="${REPO_DIR}/.github/workflows/pbrp-build.yml"
# Any interpreter with PyYAML will do; Termux ships it under `python` while
# `python3` may be a bare system interpreter.
YAML_PY=""
for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import yaml' 2>/dev/null; then
        YAML_PY="${candidate}"
        break
    fi
done
if [[ -n "${YAML_PY}" ]]; then
    if "${YAML_PY}" - "${workflow}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh)
assert isinstance(data, dict) and "jobs" in data, "workflow has no jobs"
assert "build" in data["jobs"], "workflow has no build job"
steps = data["jobs"]["build"]["steps"]
assert any(s.get("uses", "").startswith("actions/upload-artifact") for s in steps), \
    "no artifact upload step"
PY
    then pass "workflow parses and has a build job with an artifact upload"
    else fail "workflow YAML problem"
    fi
else
    echo "  skip  no interpreter with PyYAML found (pip install pyyaml to enable this check)"
fi

note "workflow build requirements"
# PBRP's vendor/pb/build/tools/roomservice.py reads this file while the build
# is parsed, so a blanket `rm -rf .repo` kills the build after the sync.
if grep -qE 'rm -rf "\$\{?PBRP_TOP\}?/\.repo"' "${workflow}"; then
    fail "workflow deletes all of .repo; roomservice.py needs .repo/manifests/default.xml"
else
    pass "workflow keeps .repo/manifests while dropping the object stores"
fi

# make-vendor-boot.sh writes the digest beside the image under a bare file name,
# so that `sha256sum -c vendor_boot-rodin.img.sha256` works in place once the
# artifact is unzipped. `sha256sum --check` resolves that name against the
# current directory, so the workflow has to read the file from the image's own
# directory: step 17 checked it from the workspace root and died with "No such
# file or directory" after step 15 and step 16 had both already succeeded, and
# the finished image was thrown away.
if grep -qE 'cd "\$\(dirname "\$\{?OUT_IMAGE\}?"\)"' \
        "${REPO_DIR}/device/xiaomi/rodin/tools/make-vendor-boot.sh"; then
    pass "make-vendor-boot.sh writes the checksum file beside the image"
else
    fail "make-vendor-boot.sh no longer writes the checksum beside the image"
fi
sha_lines=0
sha_offenders=0
while IFS= read -r line; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" == *"sha256sum --check"* ]] || continue
    sha_lines=$((sha_lines + 1))
    [[ "${line}" == *'cd "$(dirname'* ]] || sha_offenders=$((sha_offenders + 1))
done < "${workflow}"
if (( sha_lines == 0 )); then
    fail "the workflow never verifies the checksum of the built image"
elif (( sha_offenders == 0 )); then
    pass "the image checksum is checked from the image's own directory"
else
    fail "${sha_offenders} sha256sum --check line(s) run outside the image directory"
fi

note "board config scope"
# AOSP marks these as readonly once board scope begins, so assigning one in
# BoardConfig.mk aborts the build with "cannot assign to readonly variable".
# This check exists because the first hosted build died exactly that way.
readonly_vars="PRODUCT_USE_DYNAMIC_PARTITIONS PRODUCT_BUILD_SUPER_PARTITION PRODUCT_BUILD_SUPER_EMPTY_IMAGE"
bad_scope=""
for v in ${readonly_vars}; do
    if grep -qE "^[[:space:]]*${v}[[:space:]]*[:+]?=[[:space:]]*" "${DEVICE_DIR}/BoardConfig.mk"; then
        bad_scope="${bad_scope} ${v}"
    fi
done
if [[ -z "${bad_scope}" ]]; then
    pass "BoardConfig.mk leaves product variables to device.mk"
else
    fail "readonly product variable(s) assigned in BoardConfig.mk:${bad_scope}"
fi
if grep -qE "^[[:space:]]*PRODUCT_USE_DYNAMIC_PARTITIONS[[:space:]]*:=" "${DEVICE_DIR}/device.mk"; then
    pass "device.mk enables dynamic partitions"
else
    fail "device.mk does not set PRODUCT_USE_DYNAMIC_PARTITIONS"
fi
# Host-only tools in the device package list abort the build in main.mk
# ("Host modules should be in PRODUCT_HOST_PACKAGES"); lpunpack did exactly
# that on the first hosted build that reached the rule parser.
host_in_device=""
for m in lpunpack lpmake lpdump_host; do
    if awk '/^PRODUCT_PACKAGES[[:space:]]*\+?=/{f=1} f && /^[[:space:]]*'"${m}"'[[:space:]]*\\?[[:space:]]*$/{found=1} /^$/{f=0} END{exit !found}' \
        "${DEVICE_DIR}/device.mk"; then
        host_in_device="${host_in_device} ${m}"
    fi
done
if [[ -z "${host_in_device}" ]]; then
    pass "device.mk lists no host-only tools in PRODUCT_PACKAGES"
else
    fail "host-only tool(s) in PRODUCT_PACKAGES:${host_in_device}"
fi

note "recovery.fstab sanity"
fstab="${DEVICE_DIR}/recovery/root/system/etc/recovery.fstab"
if grep -qE '^/dev/block/by-name/userdata[[:space:]]+/data[[:space:]]+f2fs' "${fstab}"; then
    pass "/data is mounted from the userdata partition"
else
    fail "/data entry missing from recovery.fstab"
fi
if grep -q 'logical' "${fstab}"; then
    pass "dynamic partitions are flagged logical"
else
    fail "no logical partition entries in recovery.fstab"
fi
# Dual erofs/ext4 entries for the same mount point are intentional; flag only
# an entry that repeats the same device, mount point *and* filesystem type.
dupes="$(awk '!/^#/ && NF >= 4 {key = $1" "$2" "$3; if (seen[key]++) print $2}' "${fstab}" | sort -u)"
if [[ -z "${dupes}" ]]; then
    pass "no duplicated device/mount/fstype entries"
else
    fail "duplicated entries for: ${dupes}"
fi

note "platform ramdisk"
# make-vendor-boot.sh keeps the platform fragment verbatim. It is the
# first-stage environment that normal boot and recovery both run against, so
# nothing is pruned out of it any more; it is only recompressed from LZ4 to
# zstd -19, which is what makes room for a PBRP-sized recovery fragment. The
# checks below guard that: the blob really carries what first stage needs, and
# the packer does not grow a prune list again.
boot_script="${DEVICE_DIR}/tools/make-vendor-boot.sh"
platform_ramdisk="${DEVICE_DIR}/prebuilt/vendor_ramdisk00"
if [[ ! -s "${platform_ramdisk}" ]]; then
    echo "  skip  prebuilt/vendor_ramdisk00 is missing, cannot check the platform"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "  skip  python3 is missing, cannot list the platform ramdisk"
else
    members_file="${HARNESS}/platform-members.txt"
    if ! python3 "${DEVICE_DIR}/tools/vendor_ramdisk.py" list "${platform_ramdisk}" > "${members_file}" 2>/dev/null; then
        fail "vendor_ramdisk.py cannot list ${platform_ramdisk}"
    else
        members="$(awk '{print $3}' "${members_file}")"
        # The first-stage runtime, the module loader, the firmware fstab and the
        # BootControl manifest. Nothing may remove them; if the prebuilt is ever
        # replaced by a pruned copy, this is where it shows.
        platform_essentials="
system/bin/init
system/bin/linker64
system/lib64/libc.so
lib/modules/modules.load
first_stage_ramdisk/fstab.mt6899
system/etc/vintf/manifest/android.hardware.boot-service.mtk.xml
"
        absent=""
        for f in ${platform_essentials}; do
            grep -qxF "${f}" <<< "${members}" || absent="${absent} ${f}"
        done
        if [[ -z "${absent}" ]]; then
            pass "the platform fragment carries the first-stage essentials"
        else
            fail "the platform fragment is missing:${absent}"
        fi

        if ! grep -q '^PLATFORM_PRUNE_PATHS=' "${boot_script}" &&
           ! grep -q '^PLATFORM_CORE_ESSENTIALS=' "${boot_script}"; then
            pass "the packer carries no platform prune list"
        else
            fail "make-vendor-boot.sh prunes the platform fragment again"
        fi

        if grep -q '^prepare_platform()' "${boot_script}" &&
           grep -q 'zstd -19 -T1 -q -f' "${boot_script}" &&
           grep -q 'COMBINED_RAMDISK_LIMIT=62000000' "${boot_script}"; then
            pass "the platform is recompressed with zstd -19 under the 62000000-byte limit"
        else
            fail "the packer no longer recompresses the platform with zstd -19, or lost the 62000000 limit"
        fi

        # The prebuilt is fixed: the number only changes when the blob does.
        modules="$(grep -cE '^lib/modules/[^/]+[.]ko$' <<< "${members}")"
        if [[ "${modules}" -eq 244 ]]; then
            pass "the platform fragment carries its 244 kernel modules"
        else
            fail "the platform fragment carries ${modules} kernel modules, expected 244"
        fi

            # A module built for another kernel revision can never load: the
            # kernel compares vermagic before it looks at anything else. That is
            # how a build that passes every other check ends up with no touch —
            # or, when it is the platform fragment that is stale, no storage and
            # a boot loop after the logo. Compare the recovery modules in the
            # tree against the modules inside the platform ramdisk they will run
            # next to. Reported as a warning, not a failure: the matching
            # modules only exist inside the firmware dump on the device.
            sample_module="$(grep -E '^lib/modules/[^/]+[.]ko$' <<< "${members}" | head -1)"
            platform_vermagic=""
            if [[ -n "${sample_module}" ]]; then
                extract_dir="${HARNESS}/platform-module"
                rm -rf "${extract_dir}"
                if python3 "${DEVICE_DIR}/tools/vendor_ramdisk.py" extract \
                        "${platform_ramdisk}" --to "${extract_dir}" \
                        --match "$(basename "${sample_module}")" >/dev/null 2>&1; then
                    platform_vermagic="$(grep -ao 'vermagic=[^[:space:]]*' \
                        "${extract_dir}/$(basename "${sample_module}")" | head -1 | cut -d= -f2)"
                fi
            fi
            if [[ -z "${platform_vermagic}" ]]; then
                echo "  skip  could not read vermagic out of ${platform_ramdisk}"
            else
                mismatched=""
                for m in "${DEVICE_DIR}"/prebuilt/modules/*.ko; do
                    [[ -e "${m}" ]] || continue
                    module_vermagic="$(grep -ao 'vermagic=[^[:space:]]*' "${m}" | head -1 | cut -d= -f2)"
                    [[ "${module_vermagic}" == "${platform_vermagic}" ]] || \
                        mismatched="${mismatched} $(basename "${m}")"
                done
                if [[ -z "${mismatched}" ]]; then
                    pass "the recovery modules match the platform ramdisk's kernel (${platform_vermagic})"
                else
                    warn "prebuilt/modules was built for another kernel revision:${mismatched}"
                    warn "  platform ramdisk vermagic: ${platform_vermagic}"
                    warn "  every insmod of these will fail on a device running this firmware;"
                    warn "  re-pull them from the installed revision (vendor_dlkm inside super.img)"
                fi
            fi

            # The platform fragment is packed exactly as archived; only the
            # recovery fragment and the AVB-disabled repack touch anything.
            if grep -q 'prepare_platform "${platform_blob}" "${codec}" "${strip}"' "${boot_script}" &&
               grep -q 'build_image "${out}" "${stock}" "${platform}"' "${boot_script}"; then
                pass "the image is assembled from the platform fragment as shipped"
            else
                fail "make-vendor-boot.sh no longer packs the platform fragment it was given"
            fi

            # The recovery trim is the other half of the size fix: without it the
            # fragment alone is 41 MiB and the combined size loops on the device.
            trim_paths="$(sed -n '/^RECOVERY_TRIM_PATHS="/,/^"$/p' "${boot_script}" | sed '1d;$d')"
            recovery_essentials="$(sed -n '/^RECOVERY_ESSENTIALS="/,/^"$/p' "${boot_script}" | sed '1d;$d')"
            if [[ -z "${trim_paths}" || -z "${recovery_essentials}" ]]; then
                fail "cannot read the recovery trim out of make-vendor-boot.sh"
            elif grep -qF 'languages' <<< "${trim_paths}${recovery_essentials}" &&
                 ! grep -q 'twres/languages' "${boot_script}"; then
                fail "the recovery trim does not touch the language files"
            elif grep -qxF 'system/bin/recovery' <<< "${recovery_essentials}" &&
                 grep -qxF 'system/bin/recovery' <<< "${trim_paths}"; then
                fail "the recovery trim would delete the recovery binary"
            else
                pass "the recovery trim keeps $(wc -w <<< "${recovery_essentials}") payload files and drops $(wc -w <<< "${trim_paths}")"
            fi
        fi
    fi

note "AVB footer room"
# avbtool writes its hash footer into the tail of the partition, so the image it
# signs has to stop 69632 bytes short of the partition end. That number is not
# obvious and the failure only shows after a full 50-minute build:
#   avbtool: Adding hash_footer failed: Image size of 67108864 exceeds maximum
#   image size of 67039232 in order to fit in a partition size of 67108864.
# The packer is therefore told to write just the page-aligned content
# (--no-pad) when the result will be signed, and avbtool pads it back to the
# partition size; an unsigned image keeps the full padding, because then it is
# the image that gets flashed.
boot_tool="${DEVICE_DIR}/tools/vendor_boot_tool.py"
reserve="$(sed -n 's/^AVB_FOOTER_RESERVE=\([0-9][0-9]*\).*/\1/p' "${boot_script}" | head -1)"
if [[ -n "${reserve}" ]] && (( reserve >= 69632 )); then
    pass "make-vendor-boot.sh reserves ${reserve} bytes for the AVB footer"
else
    fail "make-vendor-boot.sh no longer reserves room for the AVB footer"
fi
if grep -q 'PARTITION_SIZE - .*AVB_FOOTER_RESERVE' "${boot_script}" ||
   grep -q '^BUDGET=.*AVB_FOOTER_RESERVE' "${boot_script}"; then
    pass "the fragment budget accounts for the AVB footer"
else
    fail "the fragment budget ignores the AVB footer, so an oversized fragment would fail at signing instead"
fi

note "combined ramdisk limit and AVB shape"
# Measured on the device and confirmed by the reference tree: platform +
# recovery ramdisks together above 62,000,000 bytes stop booting — the kernel
# unpacks the initramfs at ramdisk_addr and runs into the next reservation. With
# the platform kept verbatim and recompressed as zstd, a PBRP-sized recovery
# fragment lands around 55 MB. The guard belongs in the packer.
limit="$(sed -n 's/^COMBINED_RAMDISK_LIMIT=\([0-9][0-9]*\).*/\1/p' "${boot_script}" | head -1)"
if [[ "${limit}" == "62000000" ]] && grep -q 'combined < COMBINED_RAMDISK_LIMIT' "${boot_script}"; then
    pass "make-vendor-boot.sh refuses a combined ramdisk of ${limit} bytes or more"
else
    fail "make-vendor-boot.sh no longer enforces the ${limit:-measured} combined-ramdisk limit"
fi

# The stock image carries an unsigned AVB hash footer (algorithm NONE, 704-byte
# vbmeta). Signing with the AOSP test key produced a 2112-byte vbmeta with a
# public key this bootloader has never accepted, so the packer must not do it.
signed_code="$(grep -v '^[[:space:]]*#' "${boot_script}")"
if grep -q -- '--algorithm SHA256_RSA' <<< "${signed_code}" ||
   grep -q -- '--key' <<< "${signed_code}" ||
   grep -q 'testkey_rsa' <<< "${signed_code}"; then
    fail "make-vendor-boot.sh signs with a key again, which is not the shape the stock image uses"
else
    pass "the AVB footer is written unsigned, matching the stock image"
fi

note "first-stage fstab ownership"
# The recovery fragment is concatenated after the platform fragment, so any
# first_stage_ramdisk/fstab.mt6899 it carries replaces the firmware's own table.
# The tree used to install a 23-line copy there; it dropped mi_ext, the 25
# product/system overlay mounts and the avb_keys list, and the device stopped
# at the POCO logo even though every other check passed.
if grep -q 'recovery/root/first_stage_ramdisk/fstab.emmc' "${DEVICE_DIR}/device.mk" &&
   ! grep -q ':recovery/root/first_stage_ramdisk/fstab.mt6899' "${DEVICE_DIR}/device.mk"; then
    pass "device.mk installs the tree fstab only as fstab.emmc"
else
    fail "device.mk installs recovery/root/first_stage_ramdisk/fstab.mt6899, which shadows the HyperOS first-stage table"
fi
if grep -q '^FORBIDDEN_RECOVERY_PATHS="' "${boot_script}" &&
   grep -q 'shadows' "${boot_script}" &&
   grep -q 'first_stage_ramdisk/fstab.mt6899' <<< "$(grep -A 2 '^FORBIDDEN_RECOVERY_PATHS="' "${boot_script}")"; then
    pass "make-vendor-boot.sh refuses a recovery fragment that shadows the platform fstab"
else
    fail "make-vendor-boot.sh no longer guards against a shadowed platform fstab"
fi
# And the platform input really has to be the firmware table that carries the
# HyperOS mounts, not a trimmed copy of our own.
platform_blob="${DEVICE_DIR}/prebuilt/vendor_ramdisk00"
if [[ -s "${platform_blob}" ]] && command -v lz4 >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
    if lz4 -d -f "${platform_blob}" "${HARNESS}/platform.cpio" >/dev/null 2>&1 &&
       ( cd "${HARNESS}" && cpio -i --to-stdout --quiet 'first_stage_ramdisk/fstab.mt6899' < platform.cpio 2>/dev/null ) > "${HARNESS}/platform-fstab" &&
       grep -q 'mi_ext' "${HARNESS}/platform-fstab" &&
       grep -q "lowerdir=/mnt/vendor/mi_ext" "${HARNESS}/platform-fstab"; then
        pass "prebuilt/vendor_ramdisk00 carries the HyperOS first-stage table (mi_ext + overlays)"
    else
        fail "prebuilt/vendor_ramdisk00 does not carry the HyperOS first-stage table"
    fi
else
    echo "  skip  lz4/cpio or prebuilt/vendor_ramdisk00 missing, cannot inspect the platform fstab"
fi

note "release profiles"
# Four images: HOS/AOSP x AVB enabled/disabled. The disabled pair differs only
# in the first-stage fstab — the avb/avb_keys flags are removed and the platform
# fragment is repacked. HOS is recompressed with zstd (verbatim content, small
# enough to fit), while AOSP keeps its imported fragment and its own bootconfig.
for needle in \
    'vendor_boot-rodin-${name}-${suffix}.img' \
    'strip_fstab_avb' \
    'assert_no_fstab_avb' \
    'prepare_platform' \
    'import-aosp-vendor-boot.sh'; do
    if grep -qF "${needle}" "${boot_script}" || grep -qF "${needle}" "${DEVICE_DIR}/tools/import-aosp-vendor-boot.sh" 2>/dev/null; then
        pass "the packer carries: ${needle}"
    else
        fail "the packer lost: ${needle}"
    fi
done
if [[ -x "${DEVICE_DIR}/tools/import-aosp-vendor-boot.sh" ]] || [[ -f "${DEVICE_DIR}/tools/import-aosp-vendor-boot.sh" ]]; then
    if bash -n "${DEVICE_DIR}/tools/import-aosp-vendor-boot.sh" 2>/dev/null; then
        pass "import-aosp-vendor-boot.sh parses"
    else
        fail "import-aosp-vendor-boot.sh does not parse"
    fi
fi
# The AOSP profile must never silently reuse the HyperOS platform fragment.
if grep -q 'AOSP_PLATFORM_RAMDISK=' "${boot_script}" &&
   grep -q 'prebuilt/aosp/vendor_ramdisk00' "${boot_script}"; then
    pass "the AOSP profile reads its own platform ramdisk"
else
    fail "the AOSP profile has no separate platform input"
fi

if grep -qF '"--no-pad"' "${boot_tool}" &&
   grep -q 'pad=not args.no_pad' "${boot_tool}" &&
   grep -q 'target = limit if pad else' "${boot_tool}"; then
    pass "vendor_boot_tool.py can write an unpadded image for the signer"
else
    fail "vendor_boot_tool.py cannot write an unpadded image, so avbtool would have no room for its footer"
fi

if grep -q 'args+=(--no-pad)' "${boot_script}" &&
   grep -qF 'SIGN' <<< "$(grep -B 2 'args+=(--no-pad)' "${boot_script}")" &&
   grep -qF '"${args[@]}"' "${boot_script}"; then
    pass "the signer gets an unpadded image while an unsigned build stays padded"
else
    fail "make-vendor-boot.sh pads the image to the full partition before signing, which avbtool refuses"
fi

# The bootconfig section is what carries the AVB-disabled override lines; the
# packer has to be able to write it at all (the stock image has none).
if grep -q 'bootconfig=None' "${boot_tool}" && grep -q -- '--bootconfig' "${boot_tool}" &&
   grep -q 'struct.pack_into("<I", header, 0x84C' "${boot_tool}"; then
    pass "vendor_boot_tool.py can write the vendor bootconfig section"
else
    fail "vendor_boot_tool.py cannot write a vendor bootconfig, so the AVB-disabled images cannot override the boot state"
fi

# The codec choice is the whole size fix: HOS must be zstd on both variants,
# AOSP keeps its own fragment for AVB-enabled and is repacked LZ4 (its fstab has
# to be edited) for AVB-disabled.
if grep -q 'build_profile HOS "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "" "AVB-ENABLED" zstd 0' "${boot_script}" &&
   grep -q 'build_profile HOS "${STOCK_IMAGE}" "${PLATFORM_RAMDISK}" "" "AVB-DISABLED" zstd 1' "${boot_script}" &&
   grep -q '"AVB-ENABLED" keep 0' "${boot_script}" &&
   grep -q '"AVB-DISABLED" lz4 1' "${boot_script}"; then
    pass "HOS is recompressed with zstd while AOSP keeps its own platform fragment"
else
    fail "the per-profile platform codec changed: HOS must be zstd, AOSP keep/lz4"
fi

# No boot-state override any more: the ROMs these images target simply do not
# run first-stage AVB, so stripping the fstab flags is the whole change.
if ! grep -q 'verifiedbootstate := "orange"' "${boot_script}"; then
    pass "the packer does not force the verified-boot state through a bootconfig"
else
    fail "make-vendor-boot.sh still writes a bootconfig override for the boot state"
fi

stock_image="${DEVICE_DIR}/prebuilt/vendor_boot_stock.img"
if [[ ! -s "${stock_image}" ]]; then
    echo "  skip  prebuilt/vendor_boot_stock.img is missing, cannot exercise --no-pad"
elif ! command -v python3 >/dev/null 2>&1; then
    echo "  skip  python3 is missing, cannot exercise --no-pad"
else
    padded="${HARNESS}/padded.img"
    unpadded="${HARNESS}/unpadded.img"
    if python3 "${boot_tool}" rebuild "${stock_image}" "${padded}" --strip-vbmeta >/dev/null 2>&1 &&
       python3 "${boot_tool}" rebuild "${stock_image}" "${unpadded}" --strip-vbmeta --no-pad >/dev/null 2>&1; then
        padded_size="$(stat -c %s "${padded}")"
        unpadded_size="$(stat -c %s "${unpadded}")"
        if (( padded_size == 67108864 && unpadded_size < 67108864 )) &&
           (( unpadded_size + ${reserve:-0} <= 67108864 )) &&
           python3 "${boot_tool}" info "${unpadded}" >/dev/null 2>&1; then
            pass "--no-pad leaves the footer room: ${unpadded_size} bytes unpadded, ${padded_size} padded"
        else
            fail "--no-pad did not stop the padding (${unpadded_size} vs ${padded_size} bytes)"
        fi
    else
        fail "vendor_boot_tool.py cannot rebuild the stock prebuilt image"
    fi
fi

note "AVB verification path"
# avbtool resolves the payload of a hash descriptor as
# <directory-of-the-image>/<partition_name>.img (AvbHashDescriptor.verify in
# avbtool.py). The image is assembled into out/target/product/rodin/, right next
# to the build's own vendor_boot.img, so verifying it there hashes that other
# file and fails with
#   sha256 digest of .../vendor_boot.img does not match digest in descriptor
# after a 40-minute build and a signing that worked. The validate step has to
# verify a copy that is the only vendor_boot.img in its directory.
validate_step="${HARNESS}/validate-step.txt"
if [[ -n "${YAML_PY}" ]]; then
    if "${YAML_PY}" - "${workflow}" > "${validate_step}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh)
for step in data["jobs"]["build"]["steps"]:
    if step.get("name") == "Validate the image":
        sys.stdout.write(step["run"])
        break
else:
    sys.exit("no Validate the image step")
PY
    then
        if grep -q 'verify_dir="\$(mktemp -d)"' "${validate_step}" &&
           grep -qF 'cp -f "$image" "$verify_dir/' "${validate_step}" &&
           grep -qF 'verify_image --image "$verify_dir/' "${validate_step}"; then
            pass "the validate step verifies the image in a directory of its own"
        else
            fail "avbtool verifies the image beside the build's own vendor_boot.img, where it compares the footer against a different file"
        fi
        partition_name="$(sed -n 's/^[[:space:]]*--partition_name[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "${boot_script}" | head -1)"
        copy_name="$(sed -n 's/.*verify_dir\/\([A-Za-z0-9_-]*\.img\).*/\1/p' "${validate_step}" | head -1)"
        if [[ -n "${partition_name}" && "${copy_name}" == "${partition_name}.img" ]]; then
            pass "the verified copy is named after the signed partition (${copy_name})"
        else
            fail "the verified copy is ${copy_name:-nothing} but the descriptor names the ${partition_name:-unknown} partition, so avbtool would never look at the image it just signed"
        fi
    else
        echo "  skip  could not read the validate step out of the workflow"
    fi
else
    echo "  skip  no interpreter with PyYAML found, cannot read the validate step"
fi

note "exec bits"
# git keeps the executable bit in the index and nowhere else. This tree is
# edited from phones: Android's /sdcard reports every file as -rw-rw---- and the
# clone runs with core.filemode=false, so a local chmod is dropped silently and
# nothing local ever complains. On the runner that commits as mode 100644 and is
# fatal — step 16 executed tools/make-vendor-boot.sh directly and died with exit
# code 126, "Permission denied", after step 15 had already spent 50 minutes
# producing vendor_boot.img. Modes are read from the index because the index is
# what git writes into the commit.
index_modes="$(git -C "${REPO_DIR}" ls-files -s 2>/dev/null || true)"
if [[ -z "${index_modes}" ]]; then
    echo "  skip  not a git checkout, cannot read committed file modes"
else
    index_mode() { awk -v p="$1" '$4 == p { print $1; exit }' <<< "${index_modes}"; }

    # 1. Scripts the workflow runs in command position. `bash foo.sh` and
    #    `python3 foo.py` bring their own interpreter; a bare `foo.sh` needs the
    #    bit. Split each line on shell separators first so `if foo.sh; then`
    #    and `x && foo.sh` count as invocations too.
    direct_bad=""
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        line="${line%%#*}"
        while IFS= read -r seg; do
            seg="${seg#"${seg%%[![:space:]]*}"}"
            token="${seg%%[[:space:]]*}"
            # Only interpreted scripts: a `for f in a.img b.dtb` list also
            # starts a segment with a path, and binaries cannot carry a
            # shebang to run through.
            case "${token}" in */*.sh|*/*.py) ;; *) continue ;; esac
            mode="$(index_mode "${token}")"
            [[ -z "${mode}" ]] && continue
            [[ "${mode}" == "100755" ]] || direct_bad="${direct_bad} ${token}"
        done < <(tr ';|&(' '\n' <<< "${line}")
    done < "${REPO_DIR}/.github/workflows/pbrp-build.yml"
    if [[ -z "${direct_bad}" ]]; then
        pass "every script the workflow executes directly is committed 100755"
    else
        fail "workflow executes non-executable file(s):${direct_bad}"
    fi

    # 2. What init execs must be executable in the ramdisk too. Every copy
    #    destination under a bin/ directory is a program init or a service
    #    starts with execve, which fails with EACCES on a 0644 file: a
    #    non-executable tee-supplicant takes the TEE services, weaver and touch
    #    down with it, and only at runtime. The reference port commits exactly
    #    these as 100755.
    if [[ -n "${dests:-}" && -n "${sources:-}" ]]; then
        read -r -a src_list <<< "${sources}"
        read -r -a dst_list <<< "${dests}"
        bin_bad=""
        for i in "${!dst_list[@]}"; do
            case "${dst_list[$i]}" in
                */bin/*) ;;
                *) continue ;;
            esac
            rel="${src_list[$i]#${REPO_DIR}/}"
            mode="$(index_mode "${rel}")"
            [[ -z "${mode}" ]] && continue
            [[ "${mode}" == "100755" ]] || bin_bad="${bin_bad} ${rel}"
        done
        if [[ -z "${bin_bad}" ]]; then
            pass "every file installed into a bin/ directory is committed 100755"
        else
            fail "installed into bin/ but committed non-executable:${bin_bad}"
        fi
    else
        echo "  skip  copy list unavailable, bin/ exec bits unchecked"
    fi
fi

note "summary"
printf 'checks: %d, failures: %d\n' "${CHECKS}" "${FAILURES}"
if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
fi
echo "tree is consistent"
