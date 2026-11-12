#!/usr/bin/env python3
"""
Rebrand the Electron runtime tree for Ainotes.

The upstream AppImage contributes the Electron/Chromium runtime.  This script
renames the executable, the CLI helper, the desktop entry, the MIME database
entry and the icon files, and rewrites the small amount of metadata that
carries the upstream brand.  Embedded binary strings are replaced in place so
the file size and ELF layout never change.

Usage:
    patch_runtime.py <appdir> <icon.png>
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import brand

NAME = "ainotes"
DISPLAY_NAME = "Ainotes"
STARTUP_WM_CLASS = "Ainotes"
ICON_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

# Brand strings compiled into the two ELF launchers.  The CLI prints the
# message, resolves its socket next to the profile and looks for a Flatpak
# socket under the application id; all references must follow the rebrand.
# The Electron binary also embeds a Bluetooth manufacturer table that happens
# to contain a company whose name starts with the old brand.
CLI_MESSAGE = (
    "The CLI is unable to find {0}. Please make sure {0} is running and try again.\n"
)
CLI_SOCKET = "%s/.{0}-cli.sock"
CLI_FLATPAK = "%s/.flatpak/md.{0}.{1}/xdg-run/.{0}-cli.sock"
BLUETOOTH_NAME = "{0} Research Corporation"


def binary_pair(template: str, *tokens: str) -> tuple[bytes, bytes]:
    """Build the (old, new) NUL-terminated byte strings for one literal."""
    old = template.format(*tokens).encode("utf-8") + b"\0"
    new = template.format(*(brand.rebrand(token) for token in tokens)).encode("utf-8") + b"\0"
    return old, new


BINARY_STRINGS = {
    NAME: [binary_pair(BLUETOOTH_NAME, brand.SOURCE_TITLE)],
    f"{NAME}-cli": [
        binary_pair(CLI_MESSAGE, brand.SOURCE_TITLE),
        binary_pair(CLI_SOCKET, brand.SOURCE_LOWER),
        binary_pair(CLI_FLATPAK, brand.SOURCE_LOWER, brand.SOURCE_TITLE),
    ],
}

DESKTOP = """[Desktop Entry]
Name={display}
Exec=AppRun --no-sandbox --class={name} %U
Terminal=false
Type=Application
Icon={name}
StartupWMClass={wm}
X-AppImage-Version=1.15.0
Comment={display} - minimal monochrome notes
MimeType=application/pdf;text/markdown;application/x-{name}-canvas;application/x-{name}-base;x-scheme-handler/{name};
Categories=Office;
""".format(display=DISPLAY_NAME, name=NAME, wm=STARTUP_WM_CLASS)

MIME = """<?xml version="1.0"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
<mime-type type="text/markdown">
  <comment>{display} document</comment>
  <glob pattern="*.md"/>
  <generic-icon name="x-office-document"/>
</mime-type>
<mime-type type="application/x-{name}-canvas">
  <comment>{display} canvas</comment>
  <glob pattern="*.canvas"/>
  <generic-icon name="x-office-document"/>
</mime-type>
<mime-type type="application/x-{name}-base">
  <comment>{display} base</comment>
  <glob pattern="*.base"/>
  <generic-icon name="x-office-document"/>
</mime-type>
</mime-info>
""".format(display=DISPLAY_NAME, name=NAME)


def rename(root: Path, old: str, new: str) -> None:
    source = root / old
    target = root / new
    if not source.exists():
        return
    if target.exists():
        target.unlink()
    source.rename(target)


def resize_icon(source: Path, target: Path, size: int) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "convert",
            str(source),
            "-resize",
            f"{size}x{size}",
            "-background",
            "none",
            "-gravity",
            "center",
            "-extent",
            f"{size}x{size}",
            str(target),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def patch_binary(path: Path, pairs: list[tuple[bytes, bytes]]) -> None:
    """Replace NUL-terminated literals in place, keeping the file size fixed."""
    data = bytearray(path.read_bytes())
    for old, new in pairs:
        if len(new) > len(old):
            raise SystemExit(f"replacement longer than original in {path}: {old!r}")
        if data.count(old) != 1:
            raise SystemExit(
                f"expected one occurrence of {old!r} in {path}, found {data.count(old)}"
            )
        at = data.index(old)
        data[at : at + len(old)] = new + b"\0" * (len(old) - len(new))
    path.write_bytes(data)
    if brand.contains_source_bytes(bytes(data)):
        raise SystemExit(f"vendor brand still present in {path}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: patch_runtime.py <appdir> <icon.png>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    icon = Path(sys.argv[2])
    if not root.is_dir() or not icon.is_file():
        print("appdir or icon missing", file=sys.stderr)
        return 1

    rename(root, brand.SOURCE_LOWER, NAME)
    rename(root, brand.SOURCE_LOWER + "-cli", f"{NAME}-cli")
    rename(root, f"md.{brand.SOURCE_LOWER}.{brand.SOURCE_TITLE}.desktop", f"{NAME}.desktop")
    rename(root / "usr/share/mime/packages", brand.SOURCE_LOWER + ".xml", f"{NAME}.xml")

    for binary_name, pairs in BINARY_STRINGS.items():
        patch_binary(root / binary_name, pairs)

    (root / f"{NAME}.desktop").write_text(DESKTOP, encoding="utf-8")
    (root / "usr/share/mime/packages" / f"{NAME}.xml").write_text(MIME, encoding="utf-8")

    # Replace every launcher icon.  Remove the old symlink first so ImageMagick
    # does not write through it and recreate the upstream icon file.
    old_root_icon = root / f"{brand.SOURCE_LOWER}.png"
    if old_root_icon.is_symlink() or old_root_icon.exists():
        old_root_icon.unlink()
    root_icon = root / f"{NAME}.png"
    if root_icon.is_symlink() or root_icon.exists():
        root_icon.unlink()
    icon_glob = f"usr/share/icons/hicolor/*/apps/{brand.SOURCE_LOWER}.png"
    for old in root.glob(icon_glob):
        old.unlink()
    for size in ICON_SIZES:
        resize_icon(icon, root / f"usr/share/icons/hicolor/{size}x{size}/apps/{NAME}.png", size)

    resize_icon(icon, root / "resources/icon.png", 512)

    root_icon.symlink_to(f"usr/share/icons/hicolor/512x512/apps/{NAME}.png")

    dir_icon = root / ".DirIcon"
    if dir_icon.is_symlink() or dir_icon.exists():
        dir_icon.unlink()
    dir_icon.symlink_to(f"usr/share/icons/hicolor/512x512/apps/{NAME}.png")

    # The AppRun wrapper hard-codes the executable name.
    apprun = root / "AppRun"
    text = apprun.read_text(encoding="utf-8")
    text = text.replace(f'BIN="$APPDIR/{brand.SOURCE_LOWER}"', f'BIN="$APPDIR/{NAME}"')
    if brand.contains_source(text):
        raise SystemExit("AppRun still contains the vendor brand")
    apprun.write_text(text, encoding="utf-8")

    leftovers = [
        str(path)
        for path in root.rglob("*")
        if brand.SOURCE_LOWER in path.name.lower()
    ]
    if leftovers:
        raise SystemExit("runtime still contains the vendor brand: " + ", ".join(leftovers))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
