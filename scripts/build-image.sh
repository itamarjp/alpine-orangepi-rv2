#!/usr/bin/env bash
# Experimental Orange Pi RV2 image builder; run as root on Ubuntu 24.04.
set -Eeuo pipefail
export LC_ALL=C
WORK="$(mktemp -d)"
LOOP=""
cleanup() {
  set +e
  for d in dev/pts dev proc sys; do mountpoint -q "$WORK/mnt/$d" && umount -lf "$WORK/mnt/$d"; done
  mountpoint -q "$WORK/mnt" && umount "$WORK/mnt"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP"
  rm -rf "$WORK"
}
trap cleanup EXIT

OUT="${OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUT"
VENDOR_URL="https://github.com/itamarjp/alpine-orangepi-rv2/releases/download/kernel-6.6.63-ky/Orangepirv2_1.0.0_ubuntu_noble_server_linux6.6.63.7z"
VENDOR_SHA="edc1d18e83e9cb509eb12dbab162555269b8255f64636a33e0ca8fcd33d865af"
curl -fL --retry 3 "$VENDOR_URL" -o "$WORK/vendor.7z"
echo "$VENDOR_SHA  $WORK/vendor.7z" | sha256sum -c -
7z x -o"$WORK/vendor" "$WORK/vendor.7z" >/dev/null
SRC="$(find "$WORK/vendor" -maxdepth 2 -name '*.img' -type f -print -quit)"
test -n "$SRC"
IMG="$OUT/alpine-orangepi-rv2-riscv64.img"
cp --reflink=auto "$SRC" "$IMG"
LOOP="$(losetup --find --show --partscan "$IMG")"
mkdir -p "$WORK/mnt" "$WORK/keep"
mount "${LOOP}p1" "$WORK/mnt"
test -f "$WORK/mnt/boot/boot.scr"
test -f "$WORK/mnt/boot/uInitrd"
test -f "$WORK/mnt/boot/Image"
test -d "$WORK/mnt/lib/modules/6.6.63-ky" || test -d "$WORK/mnt/usr/lib/modules/6.6.63-ky"
cp -a "$WORK/mnt/boot" "$WORK/keep/"
mkdir -p "$WORK/keep/lib"
cp -a "$WORK/mnt/lib/modules" "$WORK/keep/lib/"
if test -d "$WORK/mnt/lib/firmware"; then cp -a "$WORK/mnt/lib/firmware" "$WORK/keep/lib/"; fi
if test -d "$WORK/mnt/usr/lib/firmware"; then mkdir -p "$WORK/keep/usr/lib"; cp -a "$WORK/mnt/usr/lib/firmware" "$WORK/keep/usr/lib/"; fi

# Replace only the ext4 partition; MBR and the 30 MiB reserved boot area remain intact.
umount "$WORK/mnt"
mkfs.ext4 -F -L alpine-rv2 "${LOOP}p1"
mount "${LOOP}p1" "$WORK/mnt"
UUID="$(blkid -s UUID -o value "${LOOP}p1")"
ROOTFS_BASE="https://dl-cdn.alpinelinux.org/alpine/edge/releases/riscv64"
curl -fsSL "$ROOTFS_BASE/" -o "$WORK/index.html"
ROOTFS_NAME="$(grep -oE 'alpine-minirootfs-[0-9][0-9.]*-riscv64.tar.gz' "$WORK/index.html" | sort -Vu | tail -1)"
test -n "$ROOTFS_NAME"
curl -fL --retry 3 "$ROOTFS_BASE/$ROOTFS_NAME" -o "$WORK/rootfs.tar.gz"
curl -fL --retry 3 "$ROOTFS_BASE/$ROOTFS_NAME.sha256" -o "$WORK/rootfs.sha256"
(cd "$WORK"; sha256sum -c rootfs.sha256)
tar -xzf "$WORK/rootfs.tar.gz" -C "$WORK/mnt"
cp -a "$WORK/keep/." "$WORK/mnt/"
mkdir -p "$WORK/mnt/etc/apk" "$WORK/mnt/etc/network" "$WORK/mnt/etc/ssh/sshd_config.d"
printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/edge/main' 'https://dl-cdn.alpinelinux.org/alpine/edge/community' > "$WORK/mnt/etc/apk/repositories"
cp /usr/bin/qemu-riscv64-static "$WORK/mnt/usr/bin/qemu-riscv64-static"
cp /etc/resolv.conf "$WORK/mnt/etc/resolv.conf"
for d in proc sys dev; do mount --bind "/$d" "$WORK/mnt/$d"; done
mkdir -p "$WORK/mnt/dev/pts"
mount --bind /dev/pts "$WORK/mnt/dev/pts"
chroot "$WORK/mnt" /usr/bin/qemu-riscv64-static /bin/sh -eu <<'CHROOT'
apk update
apk add --no-cache alpine-base openrc openssh ifupdown-ng e2fsprogs util-linux
echo 'root:alpine' | chpasswd
ssh-keygen -A
rc-update add networking boot
rc-update add sshd default
rc-update add hostname boot
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
echo orangepi-rv2 > /etc/hostname
cat > /etc/network/interfaces <<'NETWORK'
auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp
NETWORK
cat > /etc/ssh/sshd_config.d/10-rv2.conf <<'SSH'
PasswordAuthentication yes
PermitRootLogin yes
SSH
cat > /etc/motd <<'MOTD'
Orange Pi RV2 experimental Alpine image
WARNING: Public default credentials root/alpine; change password immediately.
MOTD
CHROOT
for d in dev/pts dev proc sys; do umount "$WORK/mnt/$d"; done
rm -f "$WORK/mnt/usr/bin/qemu-riscv64-static"
cat > "$WORK/mnt/etc/fstab" <<FSTAB
UUID=$UUID / ext4 defaults,noatime 0 1
proc /proc proc defaults 0 0
FSTAB
# Orange Pi boot.cmd imports this file and uses rootdev to form root=...
if test -f "$WORK/mnt/boot/orangepiEnv.txt"; then
  sed -i -E "s|^rootdev=.*|rootdev=UUID=$UUID|" "$WORK/mnt/boot/orangepiEnv.txt"
else
  printf 'rootdev=UUID=%s\n' "$UUID" > "$WORK/mnt/boot/orangepiEnv.txt"
fi
sync
umount "$WORK/mnt"
losetup -d "$LOOP"
LOOP=""
xz -T0 -3 "$IMG"
(cd "$OUT"; sha256sum "$(basename "$IMG").xz" > SHA256SUMS)
echo "Built: $IMG.xz"
echo "EXPERIMENTAL: boot and network must be tested on physical Orange Pi RV2."
