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
MAKE

if ! command -v make >/dev/null 2>&1; then
    fail "make is not installed, cannot check device.mk copy rules"
else
    sources="$(make -s -f "${HARNESS}/harness.mk" all 2>/dev/null)"
    if [[ -z "${sources}" ]]; then
        fail "device.mk produced no PRODUCT_COPY_FILES at all"
    else
        missing=0
        count=0
        for src in ${sources}; do
            count=$((count + 1))
            if [[ ! -e "${src}" ]]; then
                fail "copy rule points at a missing file: ${src}"
                missing=1
            fi
        done
        [[ "${missing}" -eq 0 ]] && pass "all ${count} PRODUCT_COPY_FILES sources exist"
    fi

    # The blob/module rules are wildcard-guarded: create a dummy of each and
    # confirm it shows up, then remove it.
    dummy_blob="${DEVICE_DIR}/proprietary/vendor/bin/tee-supplicant"
    mkdir -p "$(dirname "${dummy_blob}")"
    : > "${dummy_blob}"
    dummy_module="${DEVICE_DIR}/prebuilt/modules/verify-dummy.ko"
    mkdir -p "$(dirname "${dummy_module}")"
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

note "summary"
printf 'checks: %d, failures: %d\n' "${CHECKS}" "${FAILURES}"
if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
fi
echo "tree is consistent"
