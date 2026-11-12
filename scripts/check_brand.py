#!/usr/bin/env python3
"""
Fail when a tree still contains a vendor brand token.

Used by the build workflow against the extracted payload and launcher.  The
token itself lives encoded in `brand.py`, so this repository contains no
plaintext reference.

Usage:
    check_brand.py <directory> [<directory> ...]
"""

from __future__ import annotations

import sys
from pathlib import Path

from brand import SOURCE_LOWER, contains_source_bytes


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: check_brand.py <directory> [...]", file=sys.stderr)
        return 2

    hits: list[Path] = []
    for name in sys.argv[1:]:
        root = Path(name)
        if not root.is_dir():
            print(f"not a directory: {root}", file=sys.stderr)
            return 2
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            try:
                data = path.read_bytes()
            except OSError:
                continue
            if contains_source_bytes(data):
                hits.append(path)

    if hits:
        print(f"vendor brand token ({SOURCE_LOWER!r}) found in:", file=sys.stderr)
        for path in hits:
            print(f"  {path}", file=sys.stderr)
        return 1

    print("brand check: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
