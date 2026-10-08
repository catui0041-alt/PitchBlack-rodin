# proprietary/ — where the recovered ROM blobs live

This directory is empty on purpose. It is populated with the binaries that the
stock ROM ships and that recovery needs, and the copy rules in
`vendor-blobs.mk` pick up whatever is present.

## Why they are needed

On rodin the recovery environment has to talk to the MiTEE stack to unlock
FBE-encrypted `/data`, and to the Xiaomi touch service to get a touchscreen.
Both are vendor binaries that are not built from the recovery sources.

## How to fill this directory

**Option A — from your own firmware dump (recommended):**

```bash
# On a PC with a full ROM dump where odm/, vendor/ and the vendor ramdisk are
# already extracted:
tools/collect-blobs.sh /path/to/firmware_dump
```

**Option B — reuse the community OrangeFox port for this board:**

```bash
tools/collect-blobs.sh --from-orangefox
```

That clones the public port, copies its `proprietary/` tree and its prebuilt
kernel/modules over, and prints what it did. Attribution and licensing notes are
in `docs/RODIN-NOTES.md`; keep the credit if you publish your tree.

## Notes

* Paths here mirror the ROM layout (`odm/...`, `vendor/...`).
* Missing files are skipped silently by `vendor-blobs.mk`; check the build log of
  a first boot to see which HALs failed to start if a feature is missing.
* Do not commit files you do not have the right to redistribute if you publish
  the tree; a private repo is fine, a public one is your call to make.
