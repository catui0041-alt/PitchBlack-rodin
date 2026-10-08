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
