---
status: investigating
trigger: "Latest build hangs at POCO logo; an older CLEAN image boots Android but recovery is black and falls back to Android."
created: 2026-11-02
updated: 2026-11-02
---

## Symptoms

- Expected: normal Android boot remains working, and recovery boot opens PBRP.
- Latest tested build: run 41449503448 (commit 6b3f3e8); tester reports a POCO-logo hang. Exact release variant has not been confirmed.
- Older tested image: `vendor_boot-rodin-DIAG-ZSTD-PBRP-CLEAN.img` from run 41341683559 (d5005af). Android reaches the home screen; recovery boot shows black, then restarts into Android.
- Original stock vendor_boot: Android and the factory recovery both work.
- User initially called the older tested file "2 zstd", but later supplied the CLEAN filename. Do not attribute this result to `DIAG-ZSTD-STOCKRECOVERY` without another confirmation.

## Current Focus

hypothesis: CLEAN changes the library ABI underneath PBRP. Keeping the binary is insufficient; PBRP needs its own library closure while stock init keeps its stock closure.
test: Stage private libraries and recovery-only service overrides; validate both ELF closures; cloud-build a separately named ISOLATED candidate.
expecting: No missing library/symbol in static checks; hardware startup, SELinux and linker compatibility remain unverified.
next_action: Finish tests and push the ISOLATED diagnostic implementation for cloud validation.

## Evidence

- timestamp: 2026-11-02
  checked: GitHub API and build log for run 41449503448.
  found: Build succeeded. Only HOS AVB-enabled/disabled and the historical alias were produced. There is no diagnostics block; diagnostics defaults to false for push builds.
  implication: Latest release images still use the uncleaned recovery fragment. Commit 0da9ef3 changes CLEAN diagnostics only, so this release is not a test of the cleanup correction.

- timestamp: 2026-11-02
  checked: Tester clarification and commit history.
  found: Old CLEAN booted Android but did not show recovery. Run 41341683559 predates the RECOVERY_OWNED_PATHS keep-list (0da9ef3).
  implication: Do not claim PBRP recovery was tested successfully, or that zstd is conclusively exonerated for every boot mode.

- timestamp: 2026-11-02
  checked: Workflow dispatch.
  found: Run 41527974781 started on main with diagnostics=true, sign_image=true, android-14.0 and build_jobs=4.
  implication: This run was subsequently cancelled by this session after discovering that the CLEAN library ABI is also incompatible; do not use it as a fix.

- timestamp: 2026-11-02
  checked: Actual ELF symbols and dependency closure from cached platform/PBRP archives; GNU_IFUNC rows handled correctly.
  found: Corrected CLEAN lacks PBRP's fs_mgr_do_mount signature and minuitwrp's android_memset16/32. The unclean closure also falls back to stock protobuf, requiring a C++ symbol missing from PBRP libc++. Stock init's original closure has no missing libraries or symbols.
  implication: Add private PBRP libraries and stop trimming protobuf. These are confirmed static ABI problems, not a complete hardware root-cause diagnosis.

## Eliminated

- hypothesis: The latest run failed to compile.
  evidence: GitHub reports success for 41449503448; reported failure now concerns device boot.
- hypothesis: The older black-screen result identifies ZSTD-STOCKRECOVERY as failing.
  evidence: User supplied a different filename (ZSTD-PBRP-CLEAN).

## Resolution

root_cause: Static CLEAN-library ABI mismatch confirmed. Full explanation of latest logo hang and old recovery fallback is not confirmed without device logs.
fix: Experimental ISOLATED diagnostic; retain PBRP protobuf, private library directory and per-service library environment; stock first-stage files retained.
verification: Nine regression tests pass; verify-tree from an unrelated cwd passes 105 checks. Full cloud ELF validation and hardware testing pending.
files_changed: make-vendor-boot.sh, two runtime tools, workflow, verify-tree, regression tests, notes, this debug record.

## Safety

Use only the tester's matching global firmware and current active slot. Preserve the known-working original vendor_boot rollback image. No bootloader locking, wipes, or writes to boot/vbmeta/preloader. Experimental recovery cannot be promised risk-free. Pause further flashing until the new candidate is verified.
