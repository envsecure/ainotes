#!/usr/bin/env python3
"""
Rebrand the application payload for Ainotes.

The upstream payload is fetched at build time and is never committed.  This
script runs against the build copy only, so `scripts/fetch-sources.sh` can
always reproduce a pristine source tree.

It rewrites every text asset (main-process code, renderer bundle, stylesheet,
locales, HTML entry points, bundled libraries and the sample vault) and any
file or directory whose name carries the upstream brand.  The rewrite is
mechanical and therefore keeps every internal reference consistent: theme
ids, CSS classes, URL schemes, MIME types, profile file names and the
self-referential links in the sample vault all move together.

Usage:
    patch_payload.py <payload-directory>
"""

from __future__ import annotations

import sys
from pathlib import Path

from brand import REPLACEMENTS

TEXT_SUFFIXES = {
    ".css",
    ".html",
    ".js",
    ".json",
    ".md",
    ".mjs",
    ".svg",
    ".txt",
    ".xml",
}


def rewrite_text(path: Path) -> int:
    """Rewrite one text asset.  Returns the number of brand tokens changed."""
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return 0

    new = text
    changed = 0
    for old, replacement in REPLACEMENTS:
        changed += new.count(old)
        new = new.replace(old, replacement)

    if new != text:
        path.write_text(new, encoding="utf-8")
    return changed


def rename_path(path: Path) -> Path:
    name = path.name
    new_name = name
    for old, replacement in REPLACEMENTS:
        new_name = new_name.replace(old, replacement)
    if new_name == name:
        return path
    target = path.with_name(new_name)
    if target.exists():
        raise SystemExit(f"cannot rename {path}: {target} already exists")
    path.rename(target)
    return target


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_payload.py <payload-directory>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"payload directory not found: {root}", file=sys.stderr)
        return 1

    files = 0
    tokens = 0
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES:
            n = rewrite_text(path)
            if n:
                files += 1
                tokens += n

    # Rename deepest paths first so parent renames cannot invalidate children.
    renamed = 0
    for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if any(old.lower() in path.name.lower() for old, _ in REPLACEMENTS):
            rename_path(path)
            renamed += 1

    print(f"rebranded payload: {files} files, {tokens} tokens, {renamed} paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
