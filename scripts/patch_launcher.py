#!/usr/bin/env python3
"""
Patch the Obsidian launcher (resources/app.asar/main.js) for the clone.

The launcher is the thin Electron bootstrap that:
  * registers the privileged `app://` scheme,
  * loads the real application payload from `obsidian.asar`,
  * downloads and signature-verifies upstream updates.

For the clone we keep every functional path intact but make the upstream
self-updater opt-in, because an automatic upstream update would silently
replace the clone's payload and drop the monochrome theme.

Two environment variables control the clone:

  OBSIDIAN_CLONE_DISABLE_UPDATE=1   (default in the clone)
      Do not download/swap in upstream `obsidian-*.asar` payloads.

  OBSIDIAN_CLONE_USER_DATA=/path
      Run against an isolated user-data directory so the clone can live
      side by side with an official Obsidian installation.

Every replacement is asserted, so a launcher change upstream fails the build
loudly instead of silently producing an unpatched clone.
"""

import sys
from pathlib import Path

MARKER = "// [obsidian-clone]"


def patch(text: str) -> str:
    orig = text

    # 1. Optional isolated user-data directory ------------------------------
    old = "let dataPath = app.getPath('userData');"
    new = (
        f"{MARKER} Optional isolated user-data directory for the clone.\n"
        "let cloneUserData = process.env.OBSIDIAN_CLONE_USER_DATA;\n"
        "if (cloneUserData) {\n"
        "\ttry {\n"
        "\t\tapp.setPath('userData', path.resolve(cloneUserData));\n"
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
        f"{MARKER} The clone keeps the updater code but disables it by default so an\n"
        "// upstream update cannot overwrite the clone's themed payload.\n"
        "let cloneDisableUpdate = process.env.OBSIDIAN_CLONE_DISABLE_UPDATE !== '0';\n"
        "\n"
        "// Only start the updater when electron is ready, because the net module requires that.\n"
        "let updatePromise = app.whenReady();"
    )
    assert text.count(old) == 1, "updatePromise anchor not found exactly once"
    text = text.replace(old, new)

    # 3. Hourly update timer ------------------------------------------------
    old = "setInterval(queueUpdate, 60 * 60 * 1000);"
    new = f"if (!cloneDisableUpdate) setInterval(queueUpdate, 60 * 60 * 1000); {MARKER}"
    assert text.count(old) == 1, "interval anchor not found exactly once"
    text = text.replace(old, new)

    # 4. Manual update request ----------------------------------------------
    old = "updateEvents.on('check', () => queueUpdate(true));"
    new = (
        f"updateEvents.on('check', () => {{ if (!cloneDisableUpdate) queueUpdate(true); }}); "
        f"{MARKER}"
    )
    assert text.count(old) == 1, "check anchor not found exactly once"
    text = text.replace(old, new)

    # 5. Startup update check -----------------------------------------------
    old = "queueUpdate();"
    new = f"if (!cloneDisableUpdate) queueUpdate(); {MARKER}"
    assert text.count(old) == 1, "startup queueUpdate anchor not found exactly once"
    text = text.replace(old, new)

    # 6. Ignore a stale upstream payload left in the user data directory -----
    old = "\t\t\tif (file.isFile() && filename.startsWith('obsidian-') && filename.endsWith('.asar')) {\n\t\t\t\tlet newVersion = extractVersion(filename);"
    new = (
        "\t\t\tif (!cloneDisableUpdate && file.isFile() && filename.startsWith('obsidian-') && filename.endsWith('.asar')) {\n"
        "\t\t\t\tlet newVersion = extractVersion(filename);"
    )
    assert text.count(old) == 1, "updated-asar detection anchor not found exactly once"
    text = text.replace(old, new)

    assert text != orig
    return text


def main() -> int:
    target = Path(sys.argv[1])
    if not target.is_file():
        print(f"launcher not found: {target}", file=sys.stderr)
        return 1

    text = target.read_text(encoding="utf-8")
    patched = patch(text)
    target.write_text(patched, encoding="utf-8")
    print(f"patched launcher: {target} ({len(text)} -> {len(patched)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
