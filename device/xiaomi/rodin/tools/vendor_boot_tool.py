#!/usr/bin/env python3
"""Parse and repack a MediaTek/AOSP vendor_boot v4 image for rodin.

Why this exists
---------------
On rodin the recovery lives in vendor_boot.img, next to two other things that
must survive: the stock *platform* vendor ramdisk (first-stage init plus the
storage/display modules MediaTek ships) and the board DTB, which MediaTek wraps
in a 64-byte header. A recovery produced by the Android build system alone
rebuilds the platform ramdisk from source, which is not equivalent to the stock
one, so the final image is assembled here instead:

    stock platform ramdisk + freshly built recovery ramdisk + stock DTB

Usage
-----
    vendor_boot_tool.py info stock_vendor_boot.img
    vendor_boot_tool.py rebuild stock_vendor_boot.img new_vendor_boot.img
    vendor_boot_tool.py rebuild stock_vendor_boot.img new.img --recovery new_ramdisk.lz4
    vendor_boot_tool.py rebuild stock_vendor_boot.img new.img \
        --platform prebuilt/vendor_ramdisk00 --dtb prebuilt/dtb/mt6899-rodin.dtb \
        --size 67108864

`rebuild` without --recovery reproduces the source byte for byte (this is the
self-test used by tools/verify-tree.sh).

Header layout is the AOSP vendor boot image header v4:
    0x000 magic "VNDRBOOT"
    0x008 header_version, 0x00C page_size
    0x010 kernel_addr, 0x014 ramdisk_addr, 0x018 vendor_ramdisk_size
    0x01C cmdline[2048]
    0x81C tags_addr, 0x820 name[16], 0x830 header_size
    0x834 dtb_size, 0x838 dtb_addr(u64)
    0x840 vendor_ramdisk_table_size, 0x844 entry_num, 0x848 entry_size,
    0x84C bootconfig_size
File order: header | vendor ramdisks | dtb | ramdisk table | bootconfig
"""

import argparse
import os
import struct
import sys

PAGE_ALIGN = 4096
DTB_MAGIC = b"\xd0\x0d\xfe\xed"
TYPE_NAMES = {0: "none", 1: "platform", 2: "recovery", 3: "dlkm"}


def align(value, page):
    return (value + page - 1) // page * page


class VendorBoot:
    def __init__(self, path):
        self.path = path
        self.size = os.path.getsize(path)
        with open(path, "rb") as fh:
            self.raw = fh.read()

        header = self.raw[:0x860]
        if header[:8] != b"VNDRBOOT":
            raise SystemExit("%s: not a vendor_boot image" % path)

        self.version = struct.unpack_from("<I", header, 0x08)[0]
        self.page_size = struct.unpack_from("<I", header, 0x0C)[0]
        self.ramdisk_size = struct.unpack_from("<I", header, 0x18)[0]
        self.dtb_size = struct.unpack_from("<I", header, 0x834)[0]
        self.table_size = struct.unpack_from("<I", header, 0x840)[0]
        self.entry_num = struct.unpack_from("<I", header, 0x844)[0]
        self.entry_size = struct.unpack_from("<I", header, 0x848)[0]
        self.bootconfig_size = struct.unpack_from("<I", header, 0x84C)[0]

        if self.version < 4:
            raise SystemExit("%s: header v%d has no ramdisk table" % (path, self.version))
        if self.page_size != PAGE_ALIGN:
            raise SystemExit("%s: unexpected page size %d" % (path, self.page_size))

        self.header = bytearray(self.raw[: self.page_size])
        self.ramdisk_start = self.page_size
        self.ramdisk_end = self.ramdisk_start + self.ramdisk_size
        self.dtb_start = align(self.ramdisk_end, self.page_size)

        window = self.raw[self.dtb_start:self.dtb_start + self.page_size]
        delta = window.find(DTB_MAGIC)
        if delta < 0:
            raise SystemExit("%s: no device tree found in the DTB section" % path)
        self.dtb_delta = delta
        self.dtb_end = self.dtb_start + delta + self.dtb_size
        self.table_start = align(self.dtb_end, self.page_size)
        self.bootconfig_start = align(self.table_start + self.table_size, self.page_size)

        self.ramdisks = []
        for i in range(self.entry_num):
            base = self.table_start + i * self.entry_size
            size, offset, rtype = struct.unpack_from("<III", self.raw, base)
            name = self.raw[base + 12:base + 12 + 32].split(b"\x00")[0].decode("utf-8", "replace")
            # Offsets are relative to the start of the vendor ramdisk section.
            data = self.raw[self.ramdisk_start + offset:
                            self.ramdisk_start + offset + size]
            if len(data) != size:
                raise SystemExit("%s: ramdisk %d is truncated" % (path, i))
            self.ramdisks.append({"name": name, "type": rtype, "data": data})

        # The MTK wrapper in front of the DTB is preserved verbatim.
        self.dtb_blob = self.raw[self.dtb_start:self.dtb_start + delta + self.dtb_size]

    # -- reporting ---------------------------------------------------------
    def describe(self):
        print("image            %s (%d bytes)" % (self.path, self.size))
        print("header_version   %d" % self.version)
        print("page_size        %d" % self.page_size)
        print("vendor_ramdisks   %d" % self.entry_num)
        for i, entry in enumerate(self.ramdisks):
            print("  [%d] %-12s type=%d (%s) %d bytes"
                  % (i, entry["name"] or "-", entry["type"],
                     TYPE_NAMES.get(entry["type"], "?"), len(entry["data"])))
        print("ramdisk section  %d bytes (offset 0x%x)" % (self.ramdisk_size, self.ramdisk_start))
        print("dtb              %d bytes at 0x%x (+%d wrapper)"
              % (self.dtb_size, self.dtb_start + self.dtb_delta, self.dtb_delta))
        print("ramdisk table    %d entries, %d bytes at 0x%x"
              % (self.entry_num, self.table_size, self.table_start))

    # -- packing -----------------------------------------------------------
    def pack(self, ramdisks, dtb_blob, out_size=None, tail=None):
        """Rebuild the image. `ramdisks` is a list of dicts with name/type/data.

        `tail` is copied verbatim after the ramdisk table. The stock image parks
        an embedded vbmeta blob (and the AVB footer) there, so keeping it makes
        a size-identical rebuild structurally identical to the original. Pass
        b"" to write an unsigned image instead; a rebuild that changes any size
        must be signed again with avbtool, because the hash descriptors in the
        stock vbmeta no longer cover the new contents.
        """
        table_entry = b""
        for index, entry in enumerate(ramdisks):
            offset = sum(len(r["data"]) for r in ramdisks[:index])
            name = entry["name"].encode()[:31]
            row = bytearray(self.entry_size)
            struct.pack_into("<III", row, 0, len(entry["data"]), offset, entry["type"])
            row[12:12 + len(name)] = name
            # board_id[16] stays zero — same as the stock table.
            table_entry += bytes(row)

        ramdisk_total = sum(len(r["data"]) for r in ramdisks)
        header = bytearray(self.header)
        struct.pack_into("<I", header, 0x18, ramdisk_total)
        struct.pack_into("<I", header, 0x834, len(dtb_blob) - self.dtb_delta)
        struct.pack_into("<I", header, 0x840, len(table_entry))
        struct.pack_into("<I", header, 0x844, len(ramdisks))
        struct.pack_into("<I", header, 0x848, self.entry_size)

        out = bytearray()
        out += header
        out += b"\x00" * (self.page_size - len(header))
        for entry in ramdisks:
            out += entry["data"]
        out += b"\x00" * (align(len(out), self.page_size) - len(out))
        out += dtb_blob
        out += b"\x00" * (align(len(out), self.page_size) - len(out))
        out += table_entry
        out += b"\x00" * (align(len(out), self.page_size) - len(out))
        # Empty bootconfig section; the tail below starts at the same offset the
        # stock image uses for its vbmeta block.
        out += b"\x00" * (self.bootconfig_size and
                          align(len(out) + self.bootconfig_size, self.page_size) - len(out))

        target = out_size or self.size
        if tail is None:
            tail = self.raw[self.bootconfig_start:]
        if len(out) + len(tail) > target:
            raise SystemExit(
                "error: the rebuilt image needs %d bytes but the partition is %d "
                "(shrink the recovery ramdisk or pass --strip-vbmeta)"
                % (len(out) + len(tail), target)
            )
        out += tail
        out += b"\x00" * (target - len(out))
        return bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    info = sub.add_parser("info", help="print the layout of an image")
    info.add_argument("image")

    rebuild = sub.add_parser("rebuild", help="write a new image")
    rebuild.add_argument("image")
    rebuild.add_argument("output")
    rebuild.add_argument("--recovery", help="replace the recovery ramdisk with this blob")
    rebuild.add_argument("--platform", help="replace the platform ramdisk with this blob")
    rebuild.add_argument("--dtb", help="replace the wrapped DTB blob with this file "
                                       "(a bare FDT is wrapped the same way as the source)")
    rebuild.add_argument("--size", type=int, default=None,
                         help="output size, defaults to the input size")
    rebuild.add_argument("--strip-vbmeta", action="store_true",
                         help="do not carry the stock embedded vbmeta/footer over")

    args = parser.parse_args()

    image = VendorBoot(args.image)
    image.describe()

    if args.command == "info":
        return 0

    ramdisks = [dict(r) for r in image.ramdisks]
    if args.platform:
        with open(args.platform, "rb") as fh:
            blob = fh.read()
        for entry in ramdisks:
            if entry["type"] == 1:
                entry["data"] = blob
                break
        else:
            sys.exit("error: no platform (type 1) ramdisk in the source image")
    if args.recovery:
        with open(args.recovery, "rb") as fh:
            blob = fh.read()
        for entry in ramdisks:
            if entry["type"] == 2:
                entry["data"] = blob
                break
        else:
            # The stock image always has a recovery fragment; add one if a
            # vendor_boot without it is used as the base.
            ramdisks.append({"name": "recovery", "type": 2, "data": blob})

    dtb_blob = image.dtb_blob
    if args.dtb:
        with open(args.dtb, "rb") as fh:
            dtb_data = fh.read()
        if dtb_data[:4] == DTB_MAGIC:
            wrapper = image.dtb_blob[:image.dtb_delta]
            dtb_blob = wrapper + dtb_data
        else:
            dtb_blob = dtb_data

    packed = image.pack(ramdisks, dtb_blob, args.size,
                        tail=b"" if args.strip_vbmeta else None)
    with open(args.output, "wb") as fh:
        fh.write(packed)
    print("wrote %s (%d bytes)" % (args.output, len(packed)))

    if args.strip_vbmeta:
        print("note: image is unsigned (vbmeta stripped). The device must have "
              "verification disabled, or sign it again with avbtool.")
    elif any(len(entry["data"]) != len(image.ramdisks[i]["data"])
             for i, entry in enumerate(ramdisks[:len(image.ramdisks)])):
        print("warning: a ramdisk size changed, so the vbmeta block carried over "
              "from the stock image no longer describes this image. Sign it "
              "again before flashing:")
        print("  avbtool add_hash_footer --image %s --partition_name vendor_boot \\"
              % args.output)
        print("      --partition_size 67108864 --algorithm SHA256_RSA4096 \\")
        print("      --key external/avb/test/data/testkey_rsa4096.pem")
    return 0


if __name__ == "__main__":
    sys.exit(main())
