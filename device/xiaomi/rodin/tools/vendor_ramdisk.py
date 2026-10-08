#!/usr/bin/env python3
__doc__ = r"""Read MediaTek vendor ramdisks and pull files out of them — pure Python.

The stock vendor ramdisk on rodin (`prebuilt/vendor_ramdisk00`) is an
LZ4 *legacy* frame wrapping a newc cpio archive. Neither the `lz4` binary nor
`cpio` has to be installed for any of this: LZ4 block decompression and cpio
parsing are implemented here, so the whole extraction also works on the phone.

Commands
--------
    # what is inside
    vendor_ramdisk.py list   prebuilt/vendor_ramdisk00
    vendor_ramdisk.py list   prebuilt/vendor_ramdisk00 --grep '\.ko$'

    # pull the recovery-only kernel modules out
    vendor_ramdisk.py extract prebuilt/vendor_ramdisk00 \
        --to prebuilt/modules --match '*.ko' --report missing

    # where does the DTB/other blob sit in the file (sanity check)
    vendor_ramdisk.py info   prebuilt/vendor_ramdisk00

Extraction is what `device.mk` expects: anything matching `prebuilt/modules/*.ko`
is packaged into the recovery ramdisk and loaded by
`recovery/root/system/bin/load-touch-modules.sh`.
"""

import argparse
import fnmatch
import os
import struct
import sys

LZ4_LEGACY = (0x184C2102, 0x184C2103)
CPIO_NEWC = b"070701"
CPIO_CRC = b"070702"
BLOCK_MAX = 8 << 20  # legacy frames use 8 MiB blocks


def lz4_block_decompress(src: bytes) -> bytes:
    """Decompress one raw LZ4 block."""
    out = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1
        literal_len = token >> 4
        if literal_len == 15:
            while i < n and src[i] == 255:
                literal_len += 255
                i += 1
            if i >= n:
                raise ValueError("truncated literal length")
            literal_len += src[i]
            i += 1
        if i + literal_len > n:
            raise ValueError("truncated literals")
        out += src[i:i + literal_len]
        i += literal_len
        if i >= n:
            break
        if i + 2 > n:
            raise ValueError("truncated match offset")
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        if offset == 0 or offset > len(out):
            raise ValueError("bad match offset %d" % offset)
        match_len = token & 0x0F
        if match_len == 15:
            while i < n and src[i] == 255:
                match_len += 255
                i += 1
            if i >= n:
                raise ValueError("truncated match length")
            match_len += src[i]
            i += 1
        match_len += 4
        start = len(out) - offset
        for j in range(match_len):
            out.append(out[start + j])
    return bytes(out)


def lz4_legacy_decompress(data: bytes) -> bytes:
    """Decompress an LZ4 legacy frame (the format MTK uses in vendor_boot)."""
    if len(data) < 8:
        raise ValueError("not an lz4 frame")
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic not in LZ4_LEGACY:
        raise ValueError("unknown lz4 legacy magic 0x%08x" % magic)
    out = bytearray()
    pos = 4
    blocks = 0
    while pos + 4 <= len(data):
        size = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        if size == 0:
            break
        if size > BLOCK_MAX or pos + size > len(data):
            # Some writers omit the trailing zero block; treat the rest as the
            # final block when the declared size clearly runs past the end.
            size = len(data) - pos
            if size <= 0:
                break
        out += lz4_block_decompress(data[pos:pos + size])
        pos += size
        blocks += 1
    if blocks == 0:
        raise ValueError("no lz4 blocks found")
    return bytes(out)


def unpack(blob: bytes) -> bytes:
    """Return the cpio archive, accepting lz4 / gzip / already-unpacked input."""
    if blob[:4] == b"\x02\x21\x4c\x18" or blob[:4] == b"\x03\x21\x4c\x18":
        return lz4_legacy_decompress(blob)
    if blob[:2] == b"\x1f\x8b":
        import gzip
        return gzip.decompress(blob)
    if blob[:6] in (CPIO_NEWC, CPIO_CRC):
        return blob
    raise ValueError("unrecognised ramdisk format (%s...)" % blob[:4].hex())


def cpio_entries(archive: bytes):
    """Yield (name, mode, data_offset, size) for a newc cpio archive."""
    pos = 0
    while pos + 110 <= len(archive):
        header = archive[pos:pos + 110]
        if header[:6] not in (CPIO_NEWC, CPIO_CRC):
            break
        fields = [int(header[6 + i * 8:14 + i * 8], 16) for i in range(13)]
        mode, _uid, _gid, _nlink, _mtime, filesize = (
            fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]
        )
        namesize = fields[11]
        name = archive[pos + 110:pos + 110 + namesize - 1].decode("utf-8", "replace")
        data_start = pos + 110 + namesize
        data_start += (4 - data_start % 4) % 4
        if name == "TRAILER!!!":
            return
        yield name, mode, data_start, filesize
        pos = data_start + filesize
        pos += (4 - pos % 4) % 4


def read_blob(path):
    if not os.path.exists(path):
        sys.exit("error: %s does not exist — run extract-prebuilts.sh first" % path)
    with open(path, "rb") as fh:
        blob = fh.read()
    try:
        archive = unpack(blob)
    except Exception as exc:  # noqa: BLE001 - the message is the point
        sys.exit("error: %s: %s" % (path, exc))
    return blob, archive


def cmd_info(args):
    blob, archive = read_blob(args.image)
    print("file            %s (%d bytes)" % (args.image, len(blob)))
    print("unpacked        %d bytes (%.1fx)" % (len(archive), len(archive) / max(len(blob), 1)))
    if archive[:4] == b"\x02\x21\x4c\x18":
        print("note            nested lz4 frame inside the cpio? check manually")
    entries = list(cpio_entries(archive))
    print("entries         %d" % len(entries))
    modules = [e for e in entries if e[0].endswith(".ko")]
    print("kernel modules  %d" % len(modules))
    for name, _mode, _off, size in modules[:40]:
        print("   %-52s %8d" % (name, size))
    if len(modules) > 40:
        print("   ... %d more" % (len(modules) - 40))


def cmd_list(args):
    _blob, archive = read_blob(args.image)
    shown = 0
    for name, mode, _off, size in cpio_entries(archive):
        if args.grep and not fnmatch.fnmatch(name, args.grep) and args.grep not in name:
            continue
        print("%-9s %10d  %s" % (oct(mode & 0o777), size, name))
        shown += 1
    print("-- %d file(s)" % shown)


# Modules the recovery needs on this board: touch (panel driver + Xiaomi touch
# service), the Sensor Control Processor, I2C glue and the haptic motor.
RECOVERY_MODULES = (
    "xiaomi_touch_rodin.ko",
    "focaltech_touch_rodin.ko",
    "goodix_core_rodin.ko",
    "nxp_i2c.ko",
    "p73.ko",
    "scp.ko",
    "si_haptic.ko",
)


def cmd_extract(args):
    _blob, archive = read_blob(args.image)
    os.makedirs(args.to, exist_ok=True)
    wanted = args.match.split(",") if args.match else ["*.ko"]
    got = []
    available = []
    for name, _mode, offset, size in cpio_entries(archive):
        base = os.path.basename(name)
        if not base:
            continue
        if any(fnmatch.fnmatch(base, pattern) for pattern in wanted):
            available.append(base)
            data = archive[offset:offset + size]
            if len(data) != size:
                sys.exit("error: short read for %s" % name)
            with open(os.path.join(args.to, base), "wb") as fh:
                fh.write(data)
            got.append((base, size))
    for base, size in sorted(got):
        mark = " (recovery-relevant)" if base in RECOVERY_MODULES else ""
        print("extracted %-46s %8d%s" % (base, size, mark))
    print("-- %d file(s) -> %s" % (len(got), args.to))

    if args.report == "missing":
        missing = [m for m in RECOVERY_MODULES if m not in available]
        if missing:
            print("\nnot present in this ramdisk (normal if the ROM ships them "
                  "differently, e.g. patched builds for the Global firmware):")
            for name in missing:
                print("   %s" % name)
        else:
            print("\nevery recovery-relevant module is present")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    info = sub.add_parser("info", help="summarise a vendor ramdisk")
    info.add_argument("image")
    info.set_defaults(func=cmd_info)

    listing = sub.add_parser("list", help="list archive members")
    listing.add_argument("image")
    listing.add_argument("--grep", help="only names containing this string")
    listing.set_defaults(func=cmd_list)

    extract = sub.add_parser("extract", help="write members to a directory")
    extract.add_argument("image")
    extract.add_argument("--to", required=True)
    extract.add_argument("--match", help="comma separated glob patterns, default '*.ko'")
    extract.add_argument("--report", choices=["none", "missing"], default="none",
                         help="report which recovery-relevant modules were absent")
    extract.set_defaults(func=cmd_extract)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
