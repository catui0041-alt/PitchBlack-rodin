# prebuilt/ — binaries taken from the stock firmware

Everything here is produced by `tools/extract-prebuilts.sh` from a stock
firmware dump of **the exact firmware revision installed on the device**. Do not
reuse a dump from another revision and expect video/touch/storage to behave;
regenerate it after every firmware update.

| File | Size (CN OS3.0.303 dump) | What it is |
|---|---|---|
| `kernel` | 17,184,688 | Kernel from `boot.img` (lz4 legacy). Kept for reference and for tooling; recovery does not carry a kernel. |
| `vendor_ramdisk00` | 29,231,353 | The stock **platform** vendor ramdisk (first-stage init + MediaTek storage/display modules). Packed back into the new vendor_boot unchanged. |
| `dtb/mt6899-rodin.dtb` | 444,841 | Bare device tree (FDT) for this board. `BOARD_PREBUILT_DTBIMAGE_DIR` points here. |
| `dtb/mt6899-rodin.dtb.mtk-wrapped` | 444,905 | Same DTB with MediaTek's 64-byte wrapper, kept for comparison. |
| `vendor_boot_stock.img` | 67,108,864 | Untouched stock `vendor_boot`. **This is the rollback image** — never delete it. |
| `modules/*.ko` | — | Optional. Recovery-only kernel modules (touch/haptics). See below. |

## Regenerating

```bash
tools/extract-prebuilts.sh /path/to/firmware/images
```

The script only slices bytes, so it runs on the phone itself. It also verifies
what it produces: lz4/cpio magic on the ramdisks, `d0 0d fe ed` on the DTB, and
that `vendor_boot.img` is exactly 67,108,864 bytes.

Verify a checked-out copy without a dump:

```bash
python3 tools/vendor_boot_tool.py info prebuilt/vendor_boot_stock.img
```

## Adding recovery-only modules (touch, haptics)

```bash
lz4 -d prebuilt/vendor_ramdisk00 vendor_ramdisk00.cpio
# extract, then copy the modules you need into prebuilt/modules/
mkdir -p prebuilt/modules
cp focaltech_touch_rodin.ko goodix_core_rodin.ko xiaomi_touch_rodin.ko scp.ko prebuilt/modules/
```

`device.mk` packages anything matching `prebuilt/modules/*.ko` plus the loader
script, and adds an init service that loads them. Module load order is in
`recovery/root/system/bin/load-touch-modules.sh`.

## Git and size

`vendor_boot_stock.img` is 64 MiB and `vendor_ramdisk00` is ~28 MiB, so the repo
carries ~95 MiB of binaries. Keep them in the repo if your host allows it
(GitHub warns above 50 MiB per file, hard limit 100 MiB) — that is what makes
the CI build reproducible without downloading firmware. If you prefer not to
commit them, add them to `.gitignore` and have the workflow fetch a dump and run
`extract-prebuilts.sh` before building.
