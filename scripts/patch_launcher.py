#!/usr/bin/env python3
"""
Patch and rebrand the Electron launcher (resources/app.asar).

The launcher is the thin Electron bootstrap that:
  * registers the privileged `app://` scheme,
  * loads the real application payload from `ainotes.asar`,
  * contains the (normally disabled) update path.

For Ainotes we keep every functional path intact but make the upstream
self-updater opt-in, because an automatic update would silently replace the
rebranded, themed payload with the stock one.

Two environment variables control the build:

  AINOTES_DISABLE_UPDATE=0
      Re-enable the update path.  It is disabled by default.

  AINOTES_USER_DATA=/path
      Run against an isolated user-data directory so Ainotes can live side by
      side with another installation.

Every replacement is asserted, so a launcher change upstream fails the build
loudly instead of silently producing an unpatched build.

Usage:
    patch_launcher.py <launcher/main.js> <launcher/package.json>
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import brand

MARKER = "// [ainotes]"

PACKAGE_NAME = "ainotes"
PACKAGE_DESCRIPTION = "Ainotes"
PACKAGE_AUTHOR = "envsecure"
PACKAGE_HOMEPAGE = "https://github.com/envsecure/ainotes"
DESKTOP_NAME = "ainotes.desktop"


def patch_main(text: str) -> str:
    orig = text

    # 1. Optional isolated user-data directory ------------------------------
    old = "let dataPath = app.getPath('userData');"
    new = (
        f"{MARKER} Optional isolated user-data directory.\n"
        "let aInotesUserData = process.env.AINOTES_USER_DATA;\n"
        "if (aInotesUserData) {\n"
        "\ttry {\n"
        "\t\tapp.setPath('userData', path.resolve(aInotesUserData));\n"
        "\t} catch (e) {\n"
        "\t\tconsole.error('Failed to set user data path', e);\n"
        "\t}\n"
        "}\n"
        "let dataPath = app.getPath('userData');"
    )
    assert text.count(old) == 1, "userData anchor not found exactly once"
    text = text.replace(old, new)

    # 2. Update switch ------------------------------------------------------
    old = "// Only start the updater when electron is ready, because the net module requires that.\nlet updatePromise = app.whenReady();"
    new = (
        f"{MARKER} Keep the update code but disable it by default so an upstream\n"
        "// update cannot overwrite the themed payload.\n"
        "let aInotesDisableUpdate = process.env.AINOTES_DISABLE_UPDATE !== '0';\n"
        "\n"
        f"{MARKER} Greyscale text rendering: Chromium's LCD subpixel antialiasing\n"
        "// paints RGB fringes on glyph edges, which is the only remaining colour\n"
        "// in an otherwise monochrome window.\n"
        "try {\n"
        "\tapp.commandLine.appendSwitch('disable-lcd-text');\n"
        "} catch (e) {\n"
        "\t}\n"
        "\n"
        "// Only start the updater when electron is ready, because the net module requires that.\n"
        "let updatePromise = app.whenReady();"
    )
    assert text.count(old) == 1, "updatePromise anchor not found exactly once"
    text = text.replace(old, new)

    # 3. Hourly update timer ------------------------------------------------
    old = "setInterval(queueUpdate, 60 * 60 * 1000);"
    new = f"if (!aInotesDisableUpdate) setInterval(queueUpdate, 60 * 60 * 1000); {MARKER}"
    assert text.count(old) == 1, "interval anchor not found exactly once"
    text = text.replace(old, new)

    # 4. Manual update request ----------------------------------------------
    old = "updateEvents.on('check', () => queueUpdate(true));"
    new = (
        f"updateEvents.on('check', () => {{ if (!aInotesDisableUpdate) queueUpdate(true); }}); "
        f"{MARKER}"
    )
    assert text.count(old) == 1, "check anchor not found exactly once"
    text = text.replace(old, new)

    # 5. Startup update check -----------------------------------------------
    old = "queueUpdate();"
    new = f"if (!aInotesDisableUpdate) queueUpdate(); {MARKER}"
    assert text.count(old) == 1, "startup queueUpdate anchor not found exactly once"
    text = text.replace(old, new)

    # 6. Ignore a stale payload left in the user data directory --------------
    old = (
        "\t\t\tif (file.isFile() && filename.startsWith('"
        + brand.SOURCE_LOWER
        + "-') && filename.endsWith('.asar')) {\n\t\t\t\tlet newVersion = extractVersion(filename);"
    )
    new = (
        "\t\t\tif (!aInotesDisableUpdate && file.isFile() && filename.startsWith('ainotes-') && filename.endsWith('.asar')) {\n"
        "\t\t\t\tlet newVersion = extractVersion(filename);"
    )
    assert text.count(old) == 1, "updated-asar detection anchor not found exactly once"
    text = text.replace(old, new)

    # 7. Rebrand every remaining reference ----------------------------------
    text = brand.rebrand(text)

    assert text != orig
    assert not brand.contains_source(text), "launcher still contains the vendor brand"
    return text


def patch_package(target: Path) -> None:
    data = json.loads(target.read_text(encoding="utf-8"))
    data["name"] = PACKAGE_NAME
    data["description"] = PACKAGE_DESCRIPTION
    data["author"] = PACKAGE_AUTHOR
    data["homepage"] = PACKAGE_HOMEPAGE
    data["desktopName"] = DESKTOP_NAME
    target.write_text(json.dumps(data, indent="\t") + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: patch_launcher.py <main.js> <package.json>", file=sys.stderr)
        return 2

    main_js = Path(sys.argv[1])
    package_json = Path(sys.argv[2])
    if not main_js.is_file() or not package_json.is_file():
        print("launcher files not found", file=sys.stderr)
        return 1

    text = main_js.read_text(encoding="utf-8")
    patched = patch_main(text)
    main_js.write_text(patched, encoding="utf-8")
    patch_package(package_json)
    print(f"patched launcher: {main_js} ({len(text)} -> {len(patched)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
