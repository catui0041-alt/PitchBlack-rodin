# proprietary/ — where the recovered ROM blobs live

This directory is empty on purpose. It is populated with the binaries that the
stock ROM ships and that recovery needs, and the copy rules in
`vendor-blobs.mk` pick up whatever is present.

## Why they are needed

On rodin the recovery environment has to talk to the MiTEE stack to unlock
FBE-encrypted `/data`, and to the Xiaomi touch service to get a touchscreen.
Both are vendor binaries that are not built from the recovery sources.

## How to fill this directory

The file list lives in `vendor-blobs.mk` and the helper reads it from there, so
the two never drift apart.

```bash
# what is present / missing right now
tools/collect-blobs.sh --check

# Option A — from your own firmware dump (recommended)
tools/collect-blobs.sh --from-dump /path/to/extracted/rom

# Option B — reuse the community OrangeFox port for this board
tools/collect-blobs.sh --from-orangefox
```

Option B clones the public port, copies its `proprietary/` tree (plus its
recovery modules when it has them) and prints what it did. Attribution and
licensing notes are in `docs/RODIN-NOTES.md`; keep the credit if you publish
your tree.

## Notes

* Paths here mirror the ROM layout (`odm/...`, `vendor/...`).
* Missing files are skipped silently by `vendor-blobs.mk`; check the build log of
  a first boot to see which HALs failed to start if a feature is missing.
* Do not commit files you do not have the right to redistribute if you publish
  the tree; a private repo is fine, a public one is your call to make.
