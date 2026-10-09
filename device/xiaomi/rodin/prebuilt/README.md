# prebuilt/ — binaries taken from the stock firmware

Everything here is produced by `tools/extract-prebuilts.sh` from a stock
firmware dump of **the exact firmware revision installed on the device**. Do not
reuse a dump from another revision and expect video/touch/storage to behave;
regenerate it after every firmware update.

## Which region *and revision* are these from? (measured, not assumed)

Measured on 2026-10-09 against the `vendor_boot` the device actually boots, and
cross-checked against the copy committed here:

* `sha256(vendor_boot_stock.img)` = `d6921924...9aa85f60`, fingerprint
  `POCO/rodin_global/rodin:15/AP3A.240905.015.A2/OS3.0.302.0.WOJMIXM:user/release-keys`,
  Android 15, security patch 2026-08-01 — **global (MIXM)**; there is no
  `WOJCNXM` token anywhere in the image.
* The platform ramdisk here is 29,241,054 bytes: 749 entries and **244 kernel
  modules, every one of them built for kernel `6.6.118-android15-8-g461cf67b3067`**.

The baseline before this one was `f3e58747...e25177` (`OS3.0.8.0.WOJMIXM`,
kernel `6.6.89-android15-8-g03fb7c87b0b5`, platform 29,231,353 bytes). A build
made from it looped on a device running OS3.0.302.0: the kernel refuses any
module whose vermagic differs, first-stage init never mounts storage, and the
phone resets right after the logo with nothing on screen. The rule is
measurable, not folklore — the reference port states it too ("the 244 type-1
platform kernel modules of Global OS3.0.301.0.WOJMIXM differ from CN
OS3.0.303.0.WOJCNXM; the DTB, fstab, first-stage init, SELinux data and the
type-2 stock recovery fragment are the same, but the **type-1 fragment cannot
be used across them**").

Consequence: this build keeps the platform ramdisk, DTB and cmdline the device
already boots, so flashing it changes only the recovery ramdisk — but **only**
for the revision the dump came from. On any other firmware revision, extract
again first: `tools/extract-prebuilts.sh`, or pull the type-1 fragment out of
that revision's `vendor_boot.img` with
`tools/vendor_boot_tool.py extract-ramdisk --type 1 --out prebuilt/vendor_ramdisk00`.
`tools/verify-tree.sh` now compares the vermagic of the modules in
`prebuilt/modules/` with the modules inside the platform ramdisk and warns when
they belong to different kernels.

| File | Size (global MIXM package dump) | What it is |
|---|---|---|
| `kernel` | 17,184,688 | Kernel from `boot.img` of the *previous* revision (lz4 legacy, kernel 6.6.89). Nothing in the build packs it — treat it as historical, and refresh it from a dump if you need it for tooling. |
| `vendor_ramdisk00` | 29,241,054 | The stock **platform** vendor ramdisk (first-stage init + 244 MediaTek modules for kernel 6.6.118). Pruned and packed into the new vendor_boot; never rebuilt from source. |
| `dtb/mt6899-rodin.dtb` | 444,841 | Bare device tree (FDT) for this board. `BOARD_PREBUILT_DTBIMAGE_DIR` points here. |
| `dtb/mt6899-rodin.dtb.mtk-wrapped` | 444,905 | Same DTB with MediaTek's 64-byte wrapper, kept for comparison. |
| `vendor_boot_stock.img` | 67,108,864 | Untouched stock `vendor_boot`. **This is the rollback image** — never delete it. |
| `modules/*.ko` | — | Optional. Recovery-only kernel modules (touch/haptics). The seven files here are built for kernel `6.6.89`, so they cannot load on a `6.6.118` device. See below. |

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

**Check the vermagic before adding any of them.** A module only loads into the
kernel it was built for; `insmod` fails quietly otherwise (the loader script
ignores errors, so recovery still boots — you just have no touch). The modules
already here say:

```
vermagic=6.6.89-android15-8-g03fb7c87b0b5-4k
```

while `prebuilt/vendor_ramdisk00` (OS3.0.302.0) carries
`vermagic=6.6.118-android15-8-g461cf67b3067-4k`. Pull the replacements out of the
firmware installed on the device — `collect-blobs.sh --from-dump <super extract>`
takes them from `vendor_dlkm` — and `tools/verify-tree.sh` will compare them
against the platform ramdisk for you.

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
