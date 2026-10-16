#!/usr/bin/env python3
"""Apply the Alpine wiki mkinitfs workaround for Orange Pi RV2.

The Ky/SpacemiT X1 remoteproc driver is built into the vendor kernel and
requests /lib/firmware/esos.elf before the real root is mounted. Stock
mkinitfs deletes staged firmware after feature files are copied. This script:

1. Appends /lib/firmware/esos.elf to features.d/base.files (wiki).
2. Optionally appends /lib/firmware/regulatory.* when wireless-regdb is installed.
3. Copies /sbin/mkinitfs to /sbin/mkinitfs-rv2 and comments out the firmware wipe.
4. Appends custom_files for esos.elf so it is copied again after initfs_firmware.
"""

from __future__ import annotations

import re
import stat
import sys
from pathlib import Path

WIPE = re.compile(
    r'^([ \t]*)rm -rf "\$tmpdir"/lib/firmware[ \t]*\n'
    r'\1mkdir -p "\$tmpdir"/lib/firmware[ \t]*$',
    re.MULTILINE,
)


def append_unique(path: Path, line: str) -> None:
    text = path.read_text() if path.exists() else ""
    lines = [item.strip() for item in text.splitlines()]
    if line not in lines:
        if text and not text.endswith("\n"):
            text += "\n"
        text += line + "\n"
        path.write_text(text)


def patch_script(source: Path, dest: Path) -> None:
    text = source.read_text()
    match = WIPE.search(text)
    if match is None:
        sys.stderr.write(
            "mkinitfs firmware wipe not found; initfs_firmware() follows:\n"
        )
        start = text.find("initfs_firmware()")
        sys.stderr.write(text[start : start + 800] if start >= 0 else text[:800])
        sys.stderr.write("\n")
        raise SystemExit("refusing to build: mkinitfs-rv2 patch did not apply")
    if len(WIPE.findall(text)) != 1:
        raise SystemExit("refusing to build: expected exactly one firmware wipe")
    indent = match.group(1)
    replacement = (
        f'{indent}#rm -rf "$tmpdir"/lib/firmware\n'
        f'{indent}[ ! -d "$tmpdir"/lib/firmware ] && mkdir -p "$tmpdir"/lib/firmware'
    )
    patched = WIPE.sub(replacement, text, count=1)
    for line in patched.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if 'rm -rf "$tmpdir"/lib/firmware' in stripped:
            raise SystemExit("refusing to build: firmware wipe is still active")
    dest.write_text(patched)
    dest.chmod(dest.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def patch_root(root: Path) -> None:
    base_files = root / "etc/mkinitfs/features.d/base.files"
    script = root / "sbin/mkinitfs"
    config = root / "etc/mkinitfs/mkinitfs.conf"
    if not base_files.is_file():
        raise SystemExit(f"missing {base_files}")
    if not script.is_file():
        raise SystemExit(f"missing {script}")
    if not config.is_file():
        raise SystemExit(f"missing {config}")

    append_unique(base_files, "/lib/firmware/esos.elf")
    firmware = root / "lib/firmware"
    if any(firmware.glob("regulatory.*")):
        append_unique(base_files, "/lib/firmware/regulatory.*")
    patch_script(script, root / "sbin/mkinitfs-rv2")

    config_text = config.read_text()
    if "esos.elf" not in config_text:
        if config_text and not config_text.endswith("\n"):
            config_text += "\n"
        config_text += (
            "\n# Copied after initfs_firmware. Feature files alone are not enough\n"
            "# when lddtree drops non-module firmware or the wipe still runs.\n"
            'custom_files="${custom_files:-} /lib/firmware/esos.elf"\n'
        )
        config.write_text(config_text)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} ROOT")
    patch_root(Path(sys.argv[1]))
    print(f"patched mkinitfs for Orange Pi RV2 under {sys.argv[1]}")


if __name__ == "__main__":
    main()
