#!/usr/bin/env python3
"""Apply reproducible build-source fixes before running the experimental builder."""
from pathlib import Path

path = Path("scripts/build-image.sh")
source = path.read_text()
replacements = {
    'ROOTFS_BASE="https://dl-cdn.alpinelinux.org/alpine/edge/releases/riscv64"': 'ROOTFS_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64"',
    'curl -fsSL "$ROOTFS_BASE/" -o "$WORK/index.html"': ': # Version pinned below',
    '''ROOTFS_NAME="$(grep -oE 'alpine-minirootfs-[0-9][0-9.]*-riscv64.tar.gz' "$WORK/index.html" | sort -Vu | tail -1)"''': 'ROOTFS_NAME="alpine-minirootfs-3.24.2-riscv64.tar.gz"',
    '(cd "$WORK"; sha256sum -c rootfs.sha256)': '''EXPECTED_SHA="$(awk 'NF {print $1; exit}' "$WORK/rootfs.sha256")"
echo "$EXPECTED_SHA  $WORK/rootfs.tar.gz" | sha256sum -c -''',
}
for old, new in replacements.items():
    if source.count(old) != 1:
        raise SystemExit(f"Expected exactly one occurrence of: {old!r}")
    source = source.replace(old, new)
path.write_text(source)
print("Pinned Alpine 3.24.2 minirootfs; APK repositories remain on edge.")
