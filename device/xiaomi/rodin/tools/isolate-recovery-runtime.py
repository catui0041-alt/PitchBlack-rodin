#!/usr/bin/env python3
"""Stage a private PBRP library runtime before removing platform-owned paths.

The stock Android 15 init still uses /system/lib64. Only the recovery services
receive the Android 14 PBRP library path. This is a diagnostic, not a claim of
hardware compatibility; validate the merged ELF dependency closure separately.
"""

import argparse
from pathlib import Path
import shutil
import tempfile

LIBRARY_PATH = "/system/lib64/pbrp:/system/lib64:/vendor/lib64/hw:/vendor/lib64"
REQUIRED_LIBRARIES = (
    "libc.so", "libc++.so", "libcutils.so", "libfs_mgr.so",
    "libprotobuf-cpp-lite.so",
)
IMPORT = "import /init.recovery.pbrp-runtime.rc"


def prepare(root):
    root = Path(root)
    libraries = root / "system/lib64"
    private = libraries / "pbrp"
    hardware = root / "init.recovery.hardware.rc"
    runtime = root / "init.recovery.pbrp-runtime.rc"
    if private.exists() or runtime.exists():
        raise ValueError("private PBRP runtime already exists; use a fresh staged root")
    for name in REQUIRED_LIBRARIES:
        path = libraries / name
        if not path.is_file() or path.is_symlink():
            raise ValueError("missing regular PBRP library: system/lib64/" + name)
    if not hardware.is_file() or hardware.is_symlink():
        raise ValueError("missing regular init.recovery.hardware.rc")
    for name in ("recovery", "adbd", "fastbootd"):
        path = root / "system/bin" / name
        if not path.is_file() or path.is_symlink():
            raise ValueError("missing regular recovery service: system/bin/" + name)

    # Snapshot before creating pbrp/ inside the source directory; copying the
    # source straight into its own child would recursively copy that child.
    with tempfile.TemporaryDirectory(prefix="rodin-runtime-") as work:
        snapshot = Path(work) / "lib64"
        shutil.copytree(libraries, snapshot, symlinks=True)
        for path in snapshot.rglob("*"):
            if not path.is_symlink():
                continue
            target = path.readlink().as_posix()
            if target.startswith("/system/lib64/"):
                path.unlink()
                path.symlink_to("/system/lib64/pbrp/" + target[len("/system/lib64/"):])
        shutil.copytree(snapshot, private, symlinks=True)

    # This file is imported only by the stock recovery init script. Per-service
    # setenv must not become a global 'export': stock init and ueventd must
    # continue to resolve their own Android 15 libraries.
    lines = ["# Generated private recovery runtime; stock init stays untouched.", ""]
    for name, command, label in (
        ("recovery", "/system/bin/recovery", "recovery"),
        ("adbd", "/system/bin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery", "adbd"),
        ("fastbootd", "/system/bin/fastbootd", "fastbootd"),
    ):
        lines += ["service " + name + " " + command, "    override", "    user root",
                  "    seclabel u:r:" + label + ":s0",
                  "    setenv LD_LIBRARY_PATH " + LIBRARY_PATH]
        if name == "recovery":
            lines.append("    socket recovery stream 422 system system")
        elif name == "adbd":
            lines += ["    disabled", "    socket adbd stream 660 system system"]
        else:
            lines += ["    disabled", "    group system"]
        lines.append("")
    lines += ["on boot", "    setprop sys.usb.config adb", ""]
    runtime.write_text("\n".join(lines))
    with hardware.open("a") as file:
        file.write("\n" + IMPORT + "\n")
    return private


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", help="fresh staging copy of recovery/root")
    args = parser.parse_args()
    try:
        private = prepare(args.root)
    except ValueError as error:
        parser.exit(1, "error: " + str(error) + "\n")
    print("private PBRP libraries staged at " + str(private))


if __name__ == "__main__":
    main()
