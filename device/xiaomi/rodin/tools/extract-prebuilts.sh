#!/usr/bin/env bash
#
# extract-prebuilts.sh — build prebuilt/ from the device's own firmware dump.
#
# Produces:
#   prebuilt/kernel                     (kernel from boot.img)
#   prebuilt/dtb/mt6899-rodin.dtb       (DTB from vendor_boot.img)
#   prebuilt/vendor_ramdisk00           (first vendor ramdisk entry)
#   prebuilt/vendor_boot_stock.img      (stock vendor_boot, kept for reference)
#
# Only byte slicing is used — no external unpacking tools and no lz4
# decompression, so the script also runs on the phone itself.
#
# Usage:
#   tools/extract-prebuilts.sh <dir-containing-boot.img-and-vendor_boot.img>
#   tools/extract-prebuilts.sh            # tries to auto-detect a dump
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${DEVICE_DIR}/prebuilt"

usage() {
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0

SRC_DIR="${1:-}"
if [[ -z "${SRC_DIR}" ]]; then
    for candidate in \
        "/storage/emulated/0/HyperOS.4.0.3.0.Rodin.CN/images" \
        "/storage/emulated/0/Download" \
        "${HOME}/rodin-firmware/images"; do
        if [[ -f "${candidate}/vendor_boot.img" && -f "${candidate}/boot.img" ]]; then
            SRC_DIR="${candidate}"
            break
        fi
    done
fi

if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
    echo "error: give me the directory that holds boot.img and vendor_boot.img" >&2
    usage 1
fi

for f in boot.img vendor_boot.img; do
    [[ -f "${SRC_DIR}/${f}" ]] || { echo "error: ${SRC_DIR}/${f} not found" >&2; exit 1; }
done

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

mkdir -p "${OUT_DIR}/dtb"

echo "== source: ${SRC_DIR}"
echo "== output: ${OUT_DIR}"

python3 - "${SRC_DIR}" "${OUT_DIR}" <<'PY'
import os
import struct
import sys

src, out = sys.argv[1], sys.argv[2]

PAGE = None  # filled from the vendor_boot header

LZ4_MAGIC = b"\x04\x22\x4d\x18"      # lz4 frame
LZ4_LEGACY = b"\x02\x21\x4c\x18"     # lz4 legacy frame (what MTK ships)
DTB_MAGIC = b"\xd0\x0d\xfe\xed"


def align(value, page):
    return (value + page - 1) // page * page


def describe(blob, name):
    if blob[:4] == LZ4_MAGIC:
        kind = "lz4 frame"
    elif blob[:4] == LZ4_LEGACY:
        kind = "lz4 legacy frame"
    elif blob[:4] == DTB_MAGIC:
        kind = "device tree"
    elif blob[:2] == b"\x1f\x8b":
        kind = "gzip"
    elif blob[:6] == b"070701":
        kind = "cpio (uncompressed)"
    elif blob[:2] == b"MZ":
        kind = "arm64 Image (PE)"
    else:
        kind = "raw/unknown (%s)" % blob[:4].hex()
    print("   %-26s %10d bytes  %s" % (name, len(blob), kind))
    return kind


def parse_boot_image(path):
    """Return (kernel_size, ramdisk_size, header_version, page_size, offsets)."""
    with open(path, "rb") as fh:
        header = fh.read(4096)
    if header[:8] != b"ANDROID!":
        raise SystemExit("error: %s is not an Android boot image" % path)

    version = struct.unpack_from("<I", header, 0x28)[0]
    if version not in (3, 4):
        raise SystemExit(
            "error: %s uses boot header v%d; this script only handles the "
            "v3/v4 GKI layout that rodin ships" % (path, version)
        )
    kernel_size, ramdisk_size = struct.unpack_from("<II", header, 0x08)
    header_size = struct.unpack_from("<I", header, 0x14)[0]
    page_size = 4096  # v3/v4 images are 4096-byte aligned
    return {
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "header_size": header_size,
        "page_size": page_size,
        "version": version,
    }


def parse_vendor_boot(path):
    with open(path, "rb") as fh:
        header = fh.read(4096)
    if header[:8] != b"VNDRBOOT":
        raise SystemExit("error: %s is not a vendor_boot image" % path)

    version = struct.unpack_from("<I", header, 0x08)[0]
    page_size = struct.unpack_from("<I", header, 0x0C)[0]
    ramdisk_size = struct.unpack_from("<I", header, 0x18)[0]
    tags_addr = struct.unpack_from("<I", header, 0x81C)[0]
    header_size = struct.unpack_from("<I", header, 0x830)[0]
    dtb_size = struct.unpack_from("<I", header, 0x834)[0]
    dtb_addr = struct.unpack_from("<Q", header, 0x838)[0]

    table_size = entry_num = entry_size = bootconfig_size = 0
    if version >= 4:
        table_size, entry_num, entry_size, bootconfig_size = struct.unpack_from(
            "<IIII", header, 0x840
        )

    info = {
        "version": version,
        "page_size": page_size,
        "ramdisk_size": ramdisk_size,
        "header_size": header_size,
        "dtb_size": dtb_size,
        "dtb_addr": dtb_addr,
        "tags_addr": tags_addr,
        "table_size": table_size,
        "entry_num": entry_num,
        "entry_size": entry_size,
        "bootconfig_size": bootconfig_size,
    }
    print("== vendor_boot header")
    for key in ("version", "page_size", "header_size", "ramdisk_size", "dtb_size",
                "table_size", "entry_num", "entry_size", "bootconfig_size"):
        print("   %-18s %s" % (key, info[key]))
    if version < 4:
        raise SystemExit("error: vendor_boot v%d has no ramdisk table" % version)
    return info


def main():
    boot = os.path.join(src, "boot.img")
    vendor_boot = os.path.join(src, "vendor_boot.img")

    print("== boot.img header")
    boot_info = parse_boot_image(boot)
    for key in ("version", "page_size", "header_size", "kernel_size", "ramdisk_size"):
        print("   %-18s %s" % (key, boot_info[key]))
    if boot_info["ramdisk_size"]:
        raise SystemExit("error: boot.img carries a ramdisk; refusing to guess which blob is the kernel")

    vinfo = parse_vendor_boot(vendor_boot)
    page = vinfo["page_size"]

    # --- vendor ramdisk section -------------------------------------------
    ramdisk_start = page
    ramdisk_end = ramdisk_start + vinfo["ramdisk_size"]
    dtb_start = align(ramdisk_end, page)

    # MediaTek wraps the FDT in a small header (observed: 64 bytes carrying the
    # FDT size), so probe the first page of the section to find where the real
    # device tree starts before working out where the ramdisk table begins.
    with open(vendor_boot, "rb") as fh:
        fh.seek(dtb_start)
        probe = fh.read(min(page, vinfo["dtb_size"]))
    dtb_delta = probe.find(DTB_MAGIC)
    if dtb_delta < 0:
        raise SystemExit(
            "error: no device tree magic found in the DTB section at 0x%x" % dtb_start
        )
    if dtb_delta:
        print("   note: FDT starts %d bytes into the section (MTK wrapper)" % dtb_delta)
    dtb_end = dtb_start + dtb_delta + vinfo["dtb_size"]
    table_start = align(dtb_end, page)

    with open(vendor_boot, "rb") as fh:
        fh.seek(table_start)
        table = fh.read(vinfo["table_size"])

    entries = []
    for i in range(vinfo["entry_num"]):
        base = i * vinfo["entry_size"]
        size, offset, rtype = struct.unpack_from("<III", table, base)
        name = table[base + 12:base + 12 + 32].split(b"\x00")[0].decode(errors="replace")
        entries.append({"size": size, "offset": offset, "type": rtype, "name": name})

    print("== vendor ramdisk table")
    for i, entry in enumerate(entries):
        print("   [%d] %-16s type=%d size=%d offset=0x%x"
              % (i, entry["name"] or "-", entry["type"], entry["size"], entry["offset"]))

    if not entries:
        raise SystemExit("error: vendor_boot reports no ramdisks")

    # The table offsets are relative to the start of the vendor ramdisk
    # section. Verify that reading, then fall back to image-absolute offsets
    # if the stock image uses the other convention.
    section_size = vinfo["ramdisk_size"]
    relative = all(e["offset"] + e["size"] <= section_size for e in entries)
    base_offset = ramdisk_start if relative else 0
    if not relative:
        absolute = all(
            e["offset"] + e["size"] <= ramdisk_end and e["offset"] >= ramdisk_start
            for e in entries
        )
        if not absolute:
            raise SystemExit(
                "error: cannot reconcile the ramdisk table with the image size "
                "(section=%d, entries=%s)" % (section_size, entries)
            )
        print("   note: table offsets are image-absolute")

    sizes = sum(e["size"] for e in entries)
    if sizes > section_size or section_size - sizes > page:
        print("   warning: ramdisk entries total %d of a %d byte section"
              % (sizes, section_size))

    with open(vendor_boot, "rb") as fh:
        # vendor ramdisk 00 = the stock vendor ramdisk (MTK storage/display
        # modules plus the vendor first-stage init).
        first = entries[0]
        fh.seek(base_offset + first["offset"])
        ramdisk = fh.read(first["size"])
        describe(ramdisk, first["name"] or "vendor_ramdisk00")
        with open(os.path.join(out, "vendor_ramdisk00"), "wb") as dst:
            dst.write(ramdisk)

        # DTB: keep the bare FDT (what BOARD_PREBUILT_DTBIMAGE_DIR expects) and
        # a copy of the MTK-wrapped original for reference.
        fh.seek(dtb_start)
        dtb = fh.read(dtb_delta + vinfo["dtb_size"])
        if dtb_delta:
            with open(os.path.join(out, "dtb", "mt6899-rodin.dtb.mtk-wrapped"),
                      "wb") as dst:
                dst.write(dtb)
        dtb = dtb[dtb_delta:]
        if len(dtb) != vinfo["dtb_size"]:
            raise SystemExit(
                "error: short read on the device tree (%d of %d bytes)"
                % (len(dtb), vinfo["dtb_size"])
            )
        describe(dtb, "dtb")
        dtb_path = os.path.join(out, "dtb", "mt6899-rodin.dtb")
        with open(dtb_path, "wb") as dst:
            dst.write(dtb)

    # Kernel (from boot.img, page-aligned right after the v4 header)
    with open(boot, "rb") as fh:
        fh.seek(boot_info["page_size"])
        kernel = fh.read(boot_info["kernel_size"])
    describe(kernel, "kernel")
    with open(os.path.join(out, "kernel"), "wb") as dst:
        dst.write(kernel)

    # Reference copy of the stock image (used to compare against a new build).
    stock_copy = os.path.join(out, "vendor_boot_stock.img")
    if not os.path.exists(stock_copy):
        with open(vendor_boot, "rb") as fh, open(stock_copy, "wb") as dst:
            while True:
                chunk = fh.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
        print("   copied stock vendor_boot.img to prebuilt/vendor_boot_stock.img")

    print("== ok")


main()
PY

echo
echo "== summary"
ls -l "${OUT_DIR}/kernel" "${OUT_DIR}/dtb/mt6899-rodin.dtb" \
      "${OUT_DIR}/vendor_ramdisk00" "${OUT_DIR}/vendor_boot_stock.img" 2>/dev/null || true
cat <<'NOTE'

Next: commit prebuilt/ (the images are a few tens of MB) or keep them out of
git and let the CI job run this script against a firmware dump it downloads.
See docs/BUILD-AND-FLASH.md.
NOTE
