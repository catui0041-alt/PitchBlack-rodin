#!/usr/bin/env python3
"""Reject missing ELF dependencies in the merged stock + recovery runtime.

Static validation only: names and exported symbols do not prove successful
relocation, correct SELinux labels, or hardware boot. Symbol versions and
runtime dlopen dependencies still need device testing.
"""

import argparse
from pathlib import Path
import re
import stat
import subprocess
import tempfile

from vendor_ramdisk import cpio_entries


def platform_files(archive):
    data = Path(archive).read_bytes()
    return {name.removeprefix("./"): (mode, data[offset:offset + size])
            for name, mode, offset, size in cpio_entries(data)}


def overlay_files(files, root):
    root = Path(root)
    for path in root.rglob("*"):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            data = path.readlink().as_posix().encode()
        elif stat.S_ISREG(mode):
            data = path.read_bytes()
        else:
            continue
        files[path.relative_to(root).as_posix()] = mode, data


def elf_symbols(data):
    with tempfile.NamedTemporaryFile(prefix="rodin-elf-") as file:
        file.write(data)
        file.flush()
        dynamic = subprocess.check_output(["readelf", "-dW", file.name], text=True)
        symbols = subprocess.check_output(["readelf", "--dyn-syms", "-W", file.name], text=True)
    needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic)
    exports, imports = set(), set()
    for line in symbols.splitlines():
        # Some readelf builds print GNU_IFUNC as three tokens instead of one.
        fields = line.replace("<OS specific>: 10", "IFUNC").split()
        if len(fields) < 8 or not fields[0].endswith(":") or not fields[0][:-1].isdigit():
            continue
        symbol = fields[7].split("@", 1)[0]
        if fields[6] != "UND" and fields[4] in ("GLOBAL", "WEAK"):
            exports.add(symbol)
        elif fields[6] == "UND" and fields[4] == "GLOBAL":
            imports.add(symbol)
    return needed, exports, imports


def check_closure(files, entry, search, parse=elf_symbols):
    pending, seen = [entry], set()
    missing, exported, imported = set(), set(), {}
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        mode, data = files.get(path, (0, b""))
        if stat.S_ISLNK(mode):
            target = data.decode()
            pending.append(target.lstrip("/") if target.startswith("/")
                           else (Path(path).parent / target).as_posix())
            continue
        if not data.startswith(b"\x7fELF"):
            missing.add(path)
            continue
        needed, exports, imports = parse(data)
        exported |= exports
        imported[path] = imports
        for name in needed:
            found = next((directory + "/" + name for directory in search
                          if directory + "/" + name in files), None)
            if found is None:
                missing.add(name)
            else:
                pending.append(found)
    unresolved = {path: sorted(symbols - exported) for path, symbols in imported.items()
                  if symbols - exported}
    return missing, unresolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform-cpio", required=True)
    parser.add_argument("--recovery-root", required=True)
    args = parser.parse_args()
    files = platform_files(args.platform_cpio)
    # The candidate must not shadow any of these firmware first-stage paths.
    protected = ("init", "system/bin/init", "system/bin/linker64", "sepolicy",
                 "prop.default", "system/etc/init/hw/init.rc",
                 "first_stage_ramdisk/fstab.mt6899")
    root = Path(args.recovery_root)
    for name in protected:
        path = root / name
        if path.exists() or path.is_symlink():
            parser.exit(1, "error: isolated recovery still shadows " + name + "\n")
    overlay_files(files, root)
    failed = False
    for entry, search in (
        ("system/bin/init", ("system/lib64", "system/lib64/bootstrap", "vendor/lib64")),
        ("system/bin/recovery", ("system/lib64/pbrp", "system/lib64", "vendor/lib64/hw", "vendor/lib64")),
        ("system/bin/adbd", ("system/lib64/pbrp", "system/lib64", "vendor/lib64/hw", "vendor/lib64")),
        ("system/bin/fastbootd", ("system/lib64/pbrp", "system/lib64", "vendor/lib64/hw", "vendor/lib64")),
    ):
        missing, unresolved = check_closure(files, entry, search)
        if missing or unresolved:
            failed = True
            print("FAIL " + entry)
            for name in sorted(missing):
                print("  missing library/file: " + name)
            for name, symbols in unresolved.items():
                print("  " + name + ": missing symbols " + ", ".join(symbols))
        else:
            print("OK merged ELF dependency closure: " + entry)
    if failed:
        parser.exit(1, "error: unresolved merged recovery runtime; do not flash\n")


if __name__ == "__main__":
    main()
