# prebuilt/ — binaries taken from the stock firmware

Everything here is produced by `tools/extract-prebuilts.sh` from a stock
firmware dump of **the exact firmware revision installed on the device**. Do not
reuse a dump from another revision and expect video/touch/storage to behave;
regenerate it after every firmware update.

## Which region are these from? (measured, not assumed)

An earlier note in this tree called the dump "CN". That was wrong. Measured on
2026-10-08 against the image actually flashed on the phone:

* `sha256(vendor_boot_stock.img)` = `f3e58747...e25177`, byte-identical to
  `images/vendor_boot.img` of the flashed fastboot package.
* Region tokens inside that package: `WOJMIXM` in `boot.img`,
  `vendor_boot.img` and `init_boot.img` — **global (MIXM)**, not `WOJCNXM`.
* Platform ramdisk here is 29,231,353 bytes; the reference port carries
  29,235,080 for its global profile and 29,188,968 for its CN profile, so this
  is a *different revision* of the global family.
* `prebuilt/modules/*.ko` (7 files) match the reference's `prebuilt/global/modules/`
  byte for byte, so the touch set is the global one.

Consequence: this build keeps the platform ramdisk, DTB and kernel that the
device already boots, so flashing it changes only the recovery ramdisk. On a
device running a *different* firmware revision (global or CN) that is no longer
true — re-run `extract-prebuilts.sh` against that revision's dump first.

| File | Size (global MIXM package dump) | What it is |
|---|---|---|
| `kernel` | 17,184,688 | Kernel from `boot.img` (lz4 legacy). Kept for reference and for tooling; recovery does not carry a kernel. |
| `vendor_ramdisk00` | 29,231,353 | The stock **platform** vendor ramdisk (first-stage init + MediaTek storage/display modules). Packed back into the new vendor_boot unchanged. |
| `dtb/mt6899-rodin.dtb` | 444,841 | Bare device tree (FDT) for this board. `BOARD_PREBUILT_DTBIMAGE_DIR` points here. |
| `dtb/mt6899-rodin.dtb.mtk-wrapped` | 444,905 | Same DTB with MediaTek's 64-byte wrapper, kept for comparison. |
| `vendor_boot_stock.img` | 67,108,864 | Untouched stock `vendor_boot`. **This is the rollback image** — never delete it. |
| `modules/*.ko` | — | Optional. Recovery-only kernel modules (touch/haptics). See below. |

## Regenerating

```bash
bash tools/extract-prebuilts.sh /path/to/firmware/images
```

The script only slices bytes, so it runs on the phone itself. It also verifies
what it produces: lz4/cpio magic on the ramdisks, `d0 0d fe ed` on the DTB, and
that `vendor_boot.img` is exactly 67,108,864 bytes.

Verify a checked-out copy without a dump:

```bash
python3 tools/vendor_boot_tool.py info prebuilt/vendor_boot_stock.img
```

## Adding recovery-only modules (touch, haptics)

Measured on this device: the stock vendor_boot contains **no recovery modules at
all** — the 244 modules in the platform ramdisk are the platform's own, and the
touch drivers live in the `vendor_dlkm` logical partition inside `super.img`.

```bash
# what is in the platform ramdisk (pure python, works on the phone)
python3 tools/vendor_ramdisk.py info prebuilt/vendor_ramdisk00

# try to pull the touch modules from it (usually finds none — see above)
bash tools/collect-blobs.sh --modules

# real options for getting them:
bash tools/collect-blobs.sh --from-orangefox        # the public port publishes them
bash tools/collect-blobs.sh --from-dump <super-extract-dir>   # from your own ROM
```

Only the modules recovery needs are ever copied here: every file in
`prebuilt/modules/` is packed into vendor_boot, whose budget for the whole
recovery ramdisk is under 36 MiB.

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
