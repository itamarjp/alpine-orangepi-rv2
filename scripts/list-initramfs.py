#!/usr/bin/env python3
"""Print filenames from a newc cpio stream, including concatenated archives."""

from __future__ import annotations

import sys


def align(value: int) -> int:
    return (value + 3) & ~3


def main() -> None:
    data = sys.stdin.buffer.read()
    index = 0
    size = len(data)
    while index < size and data[index] == 0:
        index += 1
    while index + 110 <= size:
        if data[index : index + 6] != b"070701":
            if data[index] == 0:
                index += 1
                continue
            break
        filesize = int(data[index + 54 : index + 62], 16)
        namesize = int(data[index + 94 : index + 102], 16)
        raw_name = data[index + 110 : index + 110 + namesize]
        name = raw_name.split(b"\0", 1)[0].decode("utf-8", "replace")
        if name != "TRAILER!!!":
            print(name)
        index = align(index + 110 + namesize)
        index = align(index + filesize)


if __name__ == "__main__":
    main()
