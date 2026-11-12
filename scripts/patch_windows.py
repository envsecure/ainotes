#!/usr/bin/env python3
"""
Rebrand the Windows application tree for Ainotes.

The vendor's Windows build ships the same application payload as the Linux
build, but a platform-specific launcher, a GUI executable, a console shim and
native modules.  This script renames the executables, rewrites the version
resources, replaces the icon and patches the small number of brand strings
that are compiled into the two PE files.  It also refreshes Electron's
embedded asar integrity manifest for the new file names and hashes.

Usage:
    patch_windows.py <appdir> <icon.ico> <rcedit.exe>
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import brand

NAME = "ainotes"
DISPLAY_NAME = "Ainotes"
EXE_NAME = f"{DISPLAY_NAME}.exe"
COM_NAME = f"{DISPLAY_NAME}.com"
VERSION = "1.15.0"
VERSION_STRINGS = {
    "CompanyName": "envsecure",
    "FileDescription": DISPLAY_NAME,
    "FileVersion": VERSION,
    "LegalCopyright": "Copyright (c) 2026 envsecure",
    "ProductName": DISPLAY_NAME,
    "ProductVersion": VERSION,
}

CLI_MESSAGE = "The CLI is unable to find {0}. Please make sure {0} is running and try again.\n"
CLI_PIPE = "\\\\.\\pipe\\{0}-cli-"
BLUETOOTH_NAME = "{0} Research Corporation"


def pair_ascii(template: str, token: str) -> tuple[bytes, bytes]:
    return (
        (template.format(token) + "\0").encode("ascii"),
        (template.format(brand.rebrand(token)) + "\0").encode("ascii"),
    )


def pair_utf16(template: str, token: str) -> tuple[bytes, bytes]:
    return (
        (template.format(token) + "\0").encode("utf-16le"),
        (template.format(brand.rebrand(token)) + "\0").encode("utf-16le"),
    )


BINARY_STRINGS = {
    EXE_NAME: [pair_ascii(BLUETOOTH_NAME, brand.SOURCE_TITLE)],
    COM_NAME: [
        pair_ascii(CLI_MESSAGE, brand.SOURCE_TITLE),
        pair_utf16(CLI_PIPE, brand.SOURCE_LOWER),
    ],
    "resources/app.asar.unpacked/node_modules/btime/binding.node": [
        pair_ascii(
            r"D:\Projects\{0}-stage\electron\btime\build\Release\binding.pdb",
            brand.SOURCE_LOWER,
        )
    ],
    "resources/app.asar.unpacked/node_modules/get-fonts/binding.node": [
        pair_ascii(
            r"D:\Projects\{0}-stage\electron\get-fonts\build\Release\binding.pdb",
            brand.SOURCE_LOWER,
        )
    ],
}

INTEGRITY_TYPE = "INTEGRITY"
INTEGRITY_NAME = "ELECTRONASAR"


def rename(root: Path, old: str, new: str) -> None:
    source = root / old
    target = root / new
    if not source.exists():
        return
    if target.exists():
        # The replacement has already been copied into place.
        source.unlink()
        return
    source.rename(target)


def rcedit_prefix(rcedit: Path) -> list[str]:
    if sys.platform == "win32":
        return [str(rcedit)]
    wine = os.environ.get("WINE") or shutil.which("wine64") or shutil.which("wine")
    if not wine and Path("/usr/lib/wine/wine64").is_file():
        wine = "/usr/lib/wine/wine64"
    if not wine:
        raise SystemExit("wine64 is required to run rcedit on this host")
    return [wine, str(rcedit)]


def run_rcedit(rcedit: Path, target: Path, icon: Path | None, internal: str) -> None:
    command = rcedit_prefix(rcedit) + [
        str(target),
        "--set-file-version",
        VERSION,
        "--set-product-version",
        VERSION,
    ]
    for key, value in VERSION_STRINGS.items():
        command += ["--set-version-string", key, value]
    command += ["--set-version-string", "InternalName", internal]
    command += ["--set-version-string", "OriginalFilename", target.name]
    if icon is not None:
        command += ["--set-icon", str(icon)]

    env = dict(os.environ)
    env.setdefault("WINEDEBUG", "-all")
    result = subprocess.run(command, env=env)
    if result.returncode != 0:
        raise SystemExit(f"rcedit failed for {target} ({result.returncode})")


def patch_bytes(path: Path, pairs: list[tuple[bytes, bytes]]) -> None:
    data = bytearray(path.read_bytes())
    for old, new in pairs:
        if len(new) > len(old):
            raise SystemExit(f"replacement longer than original in {path}")
        count = data.count(old)
        if count != 1:
            raise SystemExit(f"expected one occurrence of {old!r} in {path}, found {count}")
        at = data.index(old)
        data[at : at + len(old)] = new + b"\0" * (len(old) - len(new))
    path.write_bytes(data)


def find_integrity_resource(pe):
    for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        type_name = entry.name.string.decode() if entry.name else entry.id
        if type_name != INTEGRITY_TYPE:
            continue
        for item in entry.directory.entries:
            name = item.name.string.decode() if item.name else item.id
            if name != INTEGRITY_NAME:
                continue
            for lang in item.directory.entries:
                return lang.data.struct
    return None


def patch_integrity(exe: Path, appdir: Path) -> None:
    try:
        import pefile
    except ImportError:
        raise SystemExit("pefile is required (pip install pefile)")

    resources = appdir / "resources"
    manifest = []
    for name in ("app.asar", f"{NAME}.asar"):
        path = resources / name
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.append(
            {"file": f"resources\\{name}", "alg": "SHA256", "value": digest}
        )
    payload = json.dumps(manifest, separators=(",", ":")).encode("utf-8")

    pe = pefile.PE(str(exe), fast_load=True)
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_RESOURCE"]]
    )
    entry = find_integrity_resource(pe)
    if entry is None:
        raise SystemExit("embedded asar integrity manifest not found")
    if len(payload) > entry.Size:
        raise SystemExit("new integrity manifest does not fit the resource")
    offset = pe.get_offset_from_rva(entry.OffsetToData)
    with exe.open("r+b") as handle:
        handle.seek(offset)
        handle.write(payload.ljust(entry.Size, b" "))


def strip_signature(exe: Path) -> None:
    """Remove the vendor's Authenticode directory.

    rcedit changes the executable, so the original signature no longer
    verifies.  Clearing the directory is honest about the modified build and
    avoids Windows reporting a broken signature.
    """
    import pefile

    pe = pefile.PE(str(exe))
    directory = pe.OPTIONAL_HEADER.DATA_DIRECTORY[
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_SECURITY"]
    ]
    if directory.Size == 0:
        pe.close()
        return
    directory.VirtualAddress = 0
    directory.Size = 0
    pe.OPTIONAL_HEADER.CheckSum = pe.generate_checksum()
    pe.write(filename=str(exe))
    pe.close()


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: patch_windows.py <appdir> <icon.ico> <rcedit.exe>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    icon = Path(sys.argv[2])
    rcedit = Path(sys.argv[3])
    if not root.is_dir() or not icon.is_file() or not rcedit.is_file():
        print("appdir, icon or rcedit missing", file=sys.stderr)
        return 1

    rename(root, f"{brand.SOURCE_TITLE}.exe", EXE_NAME)
    rename(root, f"{brand.SOURCE_TITLE}.com", COM_NAME)
    rename(root / "resources", f"{brand.SOURCE_LOWER}.asar", f"{NAME}.asar")

    exe = root / EXE_NAME
    com = root / COM_NAME

    run_rcedit(rcedit, exe, icon, NAME)
    run_rcedit(rcedit, com, None, f"{NAME}-cli")

    for name, pairs in BINARY_STRINGS.items():
        patch_bytes(root / name, pairs)

    patch_integrity(exe, root)
    strip_signature(exe)
    strip_signature(com)

    leftovers: list[str] = []
    for path in root.rglob("*"):
        if brand.SOURCE_LOWER in path.name.lower():
            leftovers.append(str(path.relative_to(root)))
            continue
        if not path.is_file():
            continue
        if brand.contains_source_any(path.read_bytes()):
            leftovers.append(str(path.relative_to(root)))
    if leftovers:
        raise SystemExit(
            "Windows tree still contains the vendor brand: " + ", ".join(leftovers)
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
