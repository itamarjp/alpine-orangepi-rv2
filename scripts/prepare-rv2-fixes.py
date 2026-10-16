#!/usr/bin/env python3
"""Patch the experimental builder for dual Ethernet and smaller ext4 images.

Applied after prepare-build.py; fails if upstream source changes unexpectedly.
The vendor bootloader, kernel, DTB and initramfs are intentionally preserved.
"""
from pathlib import Path

p = Path("scripts/build-image.sh")
s = p.read_text()

def replace(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f"Expected exactly one match: {old[:100]!r}")
    s = s.replace(old, new)

replace("apk add --no-cache alpine-base openrc openssh ifupdown-ng e2fsprogs util-linux",
        "apk add --no-cache alpine-base openrc openssh ifupdown-ng e2fsprogs util-linux cloud-utils-growpart")
replace("auto eth0\niface eth0 inet dhcp\nNETWORK",
        "auto eth0\niface eth0 inet dhcp\nauto eth1\niface eth1 inet dhcp\nNETWORK")
replace("rc-update add sshd default",
        "rc-update add sshd default\nrc-update add rv2-grow-root default")
replace("mkdir -p \"$WORK/mnt/etc/apk\" \"$WORK/mnt/etc/network\" \"$WORK/mnt/etc/ssh/sshd_config.d\"",
        """mkdir -p "$WORK/mnt/etc/apk" "$WORK/mnt/etc/network" "$WORK/mnt/etc/ssh/sshd_config.d"
# Install one-shot root expansion service before entering the Alpine chroot.
mkdir -p "$WORK/mnt/etc/init.d"
cat > "$WORK/mnt/etc/init.d/rv2-grow-root" <<'GROW_SERVICE'
#!/sbin/openrc-run
description="Expand Orange Pi RV2 root partition on first boot"
depend() {
  need localmount
  after networking
}
start() {
  ebegin "Expanding root filesystem"
  /usr/local/sbin/rv2-grow-root
  eend $?
}
GROW_SERVICE
chmod 755 "$WORK/mnt/etc/init.d/rv2-grow-root"
mkdir -p "$WORK/mnt/usr/local/sbin"
cat > "$WORK/mnt/usr/local/sbin/rv2-grow-root" <<'GROW_SCRIPT'
#!/bin/sh
set -eu
marker=/var/lib/rv2-root-expanded
[ -e "$marker" ] && exit 0
rootdev=$(findmnt -n -o SOURCE /)
rootdev=$(readlink -f "$rootdev")
partno=$(lsblk -n -o PARTN "$rootdev" | head -1)
diskname=$(lsblk -n -o PKNAME "$rootdev" | head -1)
[ -n "$partno" ] && [ -n "$diskname" ] || { echo "Cannot identify root partition" >&2; exit 1; }
case "$rootdev" in
  /dev/mmcblk[0-9]*p[0-9]*) ;;
  *) echo "Refusing to resize non-MMC root: $rootdev" >&2; exit 1 ;;
esac
case "$disk" in
  /dev/mmcblk[0-9]*) ;;
  *) echo "Refusing to resize non-MMC disk: $disk" >&2; exit 1 ;;
esac
[ "$(findmnt -n -o FSTYPE /)" = ext4 ] || { echo "Root filesystem is not ext4" >&2; exit 1; }
growpart "$disk" "$partno"
resize2fs "$rootdev"
mkdir -p /var/lib
touch "$marker"
GROW_SCRIPT
chmod 755 "$WORK/mnt/usr/local/sbin/rv2-grow-root" """)
replace('sync\numount "$WORK/mnt"\nlosetup -d "$LOOP"\nLOOP=""\nxz -T0 -3 "$IMG"',
"""sync
umount "$WORK/mnt"
# Minimize ext4 offline, then reserve 256 MiB free for the first boot.
e2fsck -f -y "${LOOP}p1"
resize2fs -M "${LOOP}p1"
BLOCKS=$(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk -F: '/Block count:/ {gsub(/ /,"",$2); print $2}')
BLOCK_SIZE=$(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk -F: '/Block size:/ {gsub(/ /,"",$2); print $2}')
test -n "$BLOCKS" && test -n "$BLOCK_SIZE"
# 256 MiB slack; partition sector count is rounded up to whole sectors.
ROOT_BYTES=$(( BLOCKS * BLOCK_SIZE + 256 * 1024 * 1024 ))
PART_SECTORS=$(( (ROOT_BYTES + 511) / 512 ))
losetup -d "$LOOP"
LOOP=""
START_SECTOR=$(sfdisk -d "$IMG" | sed -nE 's/.*start=[[:space:]]*([0-9]+).*/\\1/p' | head -1)
test -n "$START_SECTOR"
# Preserve the existing partition start, bootloader area and partition type.
printf '%s,%s\\n' "$START_SECTOR" "$PART_SECTORS" | sfdisk --no-reread -N 1 "$IMG"
truncate -s "$(( (START_SECTOR + PART_SECTORS) * 512 ))" "$IMG"
xz -T0 -3 "$IMG" """)
p.write_text(s)
print("Enabled DHCP on both Ethernet ports, first-boot ext4 growth and image shrinking.")
