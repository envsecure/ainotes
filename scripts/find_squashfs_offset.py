#!/usr/bin/env python3
"""Locate the real squashfs payload offset inside an AppImage.

The four bytes ``hsqs`` are the squashfs superblock magic, but the sequence also
occurs by chance inside the ELF runtime, so every candidate is validated
against the superblock layout before it is accepted:

    offset + 0   magic            "hsqs"
    offset + 4   inodes           > 0
    offset + 12  block_size       power of two, 4096 .. 1048576
    offset + 20  compression id   1 gzip, 2 lzma, 3 lzo, 4 xz, 5 lz4, 6 zstd

Usage:  find_squashfs_offset.py <appimage>
Prints the byte offset of the squashfs superblock.
"""

import struct
import sys

MAGIC = b"hsqs"
COMPRESSION = {1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"}


def valid_superblock(data: bytes, offset: int) -> bool:
    if offset + 32 > len(data):
        return False
    if data[offset : offset + 4] != MAGIC:
        return False
    inodes, mkfs_time, block_size, fragments = struct.unpack(
        "<IIII", data[offset + 4 : offset + 20]
    )
    compression, block_log, flags, no_ids = struct.unpack(
        "<HHHH", data[offset + 20 : offset + 28]
    )
    if inodes == 0 or inodes > 10_000_000:
        return False
    if block_size < 4096 or block_size > 1 << 20 or block_size & (block_size - 1):
        return False
    if compression not in COMPRESSION:
        return False
    if block_log > 20:
        return False
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as handle:
        data = handle.read()

    candidates = []
    start = 0
    while True:
        index = data.find(MAGIC, start)
        if index == -1:
            break
        candidates.append(index)
        start = index + 1

    valid = [offset for offset in candidates if valid_superblock(data, offset)]
    if not valid:
        print(f"no valid squashfs superblock found in {path}", file=sys.stderr)
        return 1

    offset = valid[0]
    block_size = struct.unpack("<I", data[offset + 12 : offset + 16])[0]
    compression = COMPRESSION[struct.unpack("<H", data[offset + 20 : offset + 22])[0]]
    print(offset)
    print(
        f"# {path}: squashfs at {offset} "
        f"(block_size={block_size}, compression={compression}, "
        f"rejected candidates={candidates})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
