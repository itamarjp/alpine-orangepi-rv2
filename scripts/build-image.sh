#!/usr/bin/env bash
# Build a fresh Alpine riscv64 GPT image for the Orange Pi RV2.
#
# Assumes manufacturer OpenSBI and U-Boot are already in SPI flash and that
# this U-Boot boots extlinux/extlinux.conf. The vendor Ubuntu image is used
# only as a source of kernel 6.6.63-ky, its DTB, modules, and esos.elf.
# This script does not write SPI and does not keep the vendor boot script path.
#
# Run as root on Ubuntu 24.04. Optional cache:
#   VENDOR_7Z, VENDOR_IMG, ROOTFS_TARBALL, OUTPUT_DIR, SKIP_SHRINK=1
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/image-lib.sh"

KVER=$KVER_DEFAULT
VENDOR_URL=${VENDOR_URL:-https://github.com/itamarjp/alpine-orangepi-rv2/releases/download/kernel-6.6.63-ky/Orangepirv2_1.0.0_ubuntu_noble_server_linux6.6.63.7z}
VENDOR_SHA256=${VENDOR_SHA256:-edc1d18e83e9cb509eb12dbab162555269b8255f64636a33e0ca8fcd33d865af}
ROOTFS_NAME=${ROOTFS_NAME:-alpine-minirootfs-3.24.2-riscv64.tar.gz}
ROOTFS_URL=${ROOTFS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/${ROOTFS_NAME}}
ROOTFS_SHA256=${ROOTFS_SHA256:-57132e6e4f3a4ba9ffdf24e485513ce507e45471e7fd565aeed91c055cd63f7b}
BOOT_MIB=${BOOT_MIB:-128}
ROOT_INITIAL_MIB=${ROOT_INITIAL_MIB:-2048}
ROOT_SLACK_MIB=${ROOT_SLACK_MIB:-128}
ROOT_PASSWORD=${ROOT_PASSWORD:-alpine}
OUT=${OUTPUT_DIR:-$PWD/dist}
IMG_NAME=alpine-orangepi-rv2-riscv64.img

WORK=""
MNT=""
VENDOR_MNT=""
LOOP=""
VLOOP=""
BUILD_OK=0

cleanup() {
  set +e
  local d
  for d in "${MNT:-}/dev/pts" "${MNT:-}/dev" "${MNT:-}/proc" "${MNT:-}/sys" "${MNT:-}/boot" "${MNT:-}" "${VENDOR_MNT:-}"; do
    if [[ -n $d && -d $d ]] && mountpoint -q "$d"; then
      umount "$d" || umount -lf "$d" || true
    fi
  done
  if [[ -n $LOOP ]]; then
    losetup -d "$LOOP" || true
  fi
  if [[ -n $VLOOP ]]; then
    losetup -d "$VLOOP" || true
  fi
  if [[ -n $WORK && -d $WORK ]]; then
    rm -rf "$WORK"
  fi
  if [[ $BUILD_OK -ne 1 && -n ${IMG:-} && -f $IMG ]]; then
    rm -f "$IMG"
  fi
}
trap cleanup EXIT

sha256_file() {
  local file=$1 expected=$2
  echo "$expected  $file" | sha256sum -c - >&2
}

fetch_to() {
  local url=$1 dest=$2
  curl -fL --retry 5 --retry-delay 2 -o "$dest" "$url"
}

ensure_riscv64_binfmt() {
  # Nested exec from Alpine's shell must be handled by the kernel. Invoking
  # qemu-riscv64-static only for the first process leaves later riscv binaries
  # as "Exec format error" on qemu 8.2.
  if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
  fi
  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-riscv64 ]]; then
    local conf=/usr/lib/binfmt.d/qemu-riscv64.conf line
    [[ -f $conf ]] || die "install qemu-user-static (missing $conf)"
    line=$(grep -v '^#' "$conf" | head -n 1)
    [[ -n $line ]] || die "empty qemu-riscv64 binfmt config"
    printf '%s\n' "$line" >/proc/sys/fs/binfmt_misc/register
  fi
  [[ -e /proc/sys/fs/binfmt_misc/qemu-riscv64 ]] || die "failed to register qemu-riscv64 binfmt"
}

require_build_tools() {
  require_cmd curl 7z python3 parted sgdisk sfdisk partx losetup mkfs.ext4 blkid \
    dumpe2fs resize2fs e2fsck xz sha256sum cpio gzip findmnt
  [[ -x /usr/libexec/qemu-binfmt/riscv64-binfmt-P || -x /usr/bin/qemu-riscv64-static ]] || die "install qemu-user-static"
  [[ $EUID -eq 0 ]] || die "run as root"
  ensure_riscv64_binfmt
  grep -q "$ROOT_PASSWORD" "$SCRIPT_DIR/rootfs/etc/motd" || die "motd does not mention ROOT_PASSWORD"
  grep -q "$ROOT_PASSWORD" "$SCRIPT_DIR/rootfs/etc/issue" || die "issue does not mention ROOT_PASSWORD"
}

prepare_vendor_image() {
  local archive=$WORK/vendor.7z img
  if [[ -n ${VENDOR_IMG:-} ]]; then
    [[ -f $VENDOR_IMG ]] || die "VENDOR_IMG not found"
    printf '%s\n' "$VENDOR_IMG"
    return 0
  fi
  if [[ -n ${VENDOR_7Z:-} && -f ${VENDOR_7Z} ]]; then
    log "using cached vendor archive $VENDOR_7Z"
    sha256_file "$VENDOR_7Z" "$VENDOR_SHA256"
    archive=$VENDOR_7Z
  else
    log "downloading vendor archive"
    fetch_to "$VENDOR_URL" "$archive"
    sha256_file "$archive" "$VENDOR_SHA256"
  fi
  mkdir -p "$WORK/vendor"
  7z x -o"$WORK/vendor" "$archive" >/dev/null
  img=$(find "$WORK/vendor" -type f -name '*.img' -print -quit)
  [[ -n $img ]] || die "vendor archive has no .img"
  printf '%s\n' "$img"
}

extract_vendor_assets() {
  local img=$1 part
  VENDOR_MNT=$WORK/vendor-mnt
  mkdir -p "$VENDOR_MNT" "$WORK/assets"
  VLOOP=$(attach_loop "$img" ro)
  part=""
  local node
  for node in "${VLOOP}"p*; do
    [[ -b $node ]] || continue
    if mount -o ro "$node" "$VENDOR_MNT"; then
      if [[ -f $VENDOR_MNT/boot/vmlinuz-$KVER ]]; then
        part=$node
        break
      fi
      umount "$VENDOR_MNT"
    fi
  done
  [[ -n $part ]] || die "vendor image has no partition with boot/vmlinuz-$KVER"
  log "extracting kernel assets from $part"
  copy_kernel_assets "$VENDOR_MNT" "$WORK/assets" "$KVER"
  umount "$VENDOR_MNT"
  detach_loop "$VLOOP"
  VLOOP=""
}

prepare_rootfs_tarball() {
  local dest=$WORK/rootfs.tar.gz
  if [[ -n ${ROOTFS_TARBALL:-} && -f ${ROOTFS_TARBALL} ]]; then
    sha256_file "$ROOTFS_TARBALL" "$ROOTFS_SHA256"
    printf '%s\n' "$ROOTFS_TARBALL"
    return 0
  fi
  log "downloading $ROOTFS_NAME"
  fetch_to "$ROOTFS_URL" "$dest"
  sha256_file "$dest" "$ROOTFS_SHA256"
  printf '%s\n' "$dest"
}

install_overlay() {
  mkdir -p "$MNT/etc/network" "$MNT/etc/ssh/sshd_config.d" "$MNT/etc/init.d" "$MNT/usr/local/sbin" "$MNT/etc/apk"
  cp -a "$SCRIPT_DIR/rootfs/." "$MNT/"
  chmod 755 "$MNT/usr/local/sbin/rv2-grow-root" "$MNT/etc/init.d/rv2-grow-root"
}

run_chroot() {
  local mode=$1
  chroot "$MNT" /bin/sh -eu -s -- "$KVER" "$ROOT_PASSWORD" "$mode" <<'CHROOT'
kver=$1
pass=$2
mode=$3

add_svc() {
  svc=$1
  level=$2
  required=$3
  if [ ! -e "/etc/init.d/$svc" ]; then
    if [ "$required" = yes ]; then
      echo "missing required service $svc" >&2
      exit 1
    fi
    echo "skipping missing service $svc" >&2
    return 0
  fi
  if [ -e "/etc/runlevels/$level/$svc" ]; then
    return 0
  fi
  rc-update add "$svc" "$level"
}

if [ "$mode" = apk ]; then
  apk update
  apk add --no-cache \
    alpine-base alpine-baselayout alpine-conf alpine-keys alpine-release alpine-baselayout-data \
    kmod openrc dbus util-linux blkid chrony sysfsutils ssl_client openssh ca-certificates \
    ca-certificates-bundle ethtool e2fsprogs e2fsprogs-extra libudev-zero libudev-zero-helper \
    parted grep busybox-mdev-openrc procps-ng net-tools iproute2 coreutils doas sed gawk findutils bash \
    shadow pciutils mkinitfs ifupdown-ng cloud-utils-growpart wireless-regdb
  # Refresh all packages shipped by the minirootfs and installed above.
  # Stay on the configured Alpine repositories; never switch release branches.
  apk upgrade --no-cache
  exit 0
fi

add_svc devfs sysinit yes
add_svc mdev sysinit yes
add_svc hwdrivers sysinit no
add_svc modules sysinit no
add_svc dmesg sysinit no
add_svc bootmisc boot no
add_svc hostname boot yes
add_svc networking boot yes
add_svc sysctl boot no
add_svc urandom boot no
add_svc seedrng boot no
add_svc sshd default yes
add_svc chronyd default no
add_svc dbus default no
add_svc rv2-grow-root default yes

if ! grep -q 'sshd_config.d' /etc/ssh/sshd_config; then
  printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config
fi
printf '%s\n' "root:${pass}" | chpasswd
ssh-keygen -A
sed -i 's/^#ttyS0/ttyS0/' /etc/inittab
grep -q '^ttyS0::' /etc/inittab
depmod "$kver"
mkinitfs-rv2 -c /etc/mkinitfs/mkinitfs.conf -o "/boot/initramfs-${kver}" "$kver"
CHROOT
}

configure_fstab() {
  local root_uuid=$1 boot_uuid=$2
  cat >"$MNT/etc/fstab" <<EOF
UUID=${root_uuid} / ext4 rw,relatime 0 1
UUID=${boot_uuid} /boot ext4 rw,relatime 0 2
proc /proc proc defaults 0 0
EOF
}

assemble() {
  local vendor_img rootfs_tar root_uuid boot_uuid
  vendor_img=$(prepare_vendor_image)
  extract_vendor_assets "$vendor_img"
  rootfs_tar=$(prepare_rootfs_tarball)

  IMG=$OUT/$IMG_NAME
  log "creating GPT image ($BOOT_MIB MiB boot + $ROOT_INITIAL_MIB MiB root)"
  create_gpt_image "$IMG" "$BOOT_MIB" "$ROOT_INITIAL_MIB"
  LOOP=$(attach_loop "$IMG" rw)
  mkfs.ext4 -F -L alpine-boot "${LOOP}p1"
  mkfs.ext4 -F -L alpine-root "${LOOP}p2"
  root_uuid=$(blkid -s UUID -o value "${LOOP}p2")
  boot_uuid=$(blkid -s UUID -o value "${LOOP}p1")
  [[ -n $root_uuid && -n $boot_uuid ]] || die "failed to read filesystem UUIDs"

  MNT=$WORK/mnt
  mkdir -p "$MNT"
  mount "${LOOP}p2" "$MNT"
  mkdir -p "$MNT/boot"
  mount "${LOOP}p1" "$MNT/boot"

  log "installing Alpine minirootfs and vendor kernel"
  tar -xpf "$rootfs_tar" -C "$MNT"
  copy_kernel_assets "$WORK/assets" "$MNT" "$KVER"
  install_overlay
  configure_fstab "$root_uuid" "$boot_uuid"
  cat >"$MNT/etc/alpine-orangepi-rv2" <<EOF
kernel=$KVER
minirootfs=$ROOTFS_NAME
boot=extlinux
spi=preflashed-opensbi-u-boot
hostname=orangepi-rv2
EOF
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$MNT/etc/resolv.conf"
  mount --bind /proc "$MNT/proc"
  mount --bind /sys "$MNT/sys"
  mount --bind /dev "$MNT/dev"
  mkdir -p "$MNT/dev/pts"
  mount --bind /dev/pts "$MNT/dev/pts"

  log "installing and upgrading Alpine packages under qemu-user"
  run_chroot apk
  install_overlay
  configure_fstab "$root_uuid" "$boot_uuid"
  log "patching mkinitfs and building initramfs"
  python3 "$SCRIPT_DIR/patch-mkinitfs.py" "$MNT"
  if ! run_chroot initramfs; then
    log "mkinitfs failed; retrying without feature-file firmware globs"
    sed -i -e '\|^/lib/firmware/esos.elf$|d' -e '\|^/lib/firmware/regulatory\.\*$|d' \
      "$MNT/etc/mkinitfs/features.d/base.files"
    run_chroot initramfs
  fi

  ensure_esos_in_initramfs "$MNT/boot/initramfs-$KVER" "$MNT/lib/firmware/esos.elf"
  write_extlinux "$MNT/boot/extlinux/extlinux.conf" "$root_uuid"
  assert_extlinux_file "$MNT/boot/extlinux/extlinux.conf" "$root_uuid"
  [[ -f $MNT/boot/vmlinuz-$KVER ]] || die "vmlinuz missing on boot partition"
  [[ -f $MNT/boot/$DTB_REL ]] || die "DTB missing on boot partition"
  [[ -f $MNT/lib/firmware/esos.elf ]] || die "esos.elf missing from rootfs"
  [[ ! -e $MNT/boot/boot.scr ]] || die "boot.scr must not be the Alpine boot path"
  [[ ! -e $MNT/boot/orangepiEnv.txt ]] || die "orangepiEnv.txt must not be shipped"
  grep -q '^ttyS0::' "$MNT/etc/inittab"
  grep -q 'PermitRootLogin yes' "$MNT/etc/ssh/sshd_config.d/10-rv2.conf"
  grep -q "$root_uuid" "$MNT/etc/fstab"
  grep -q "$boot_uuid" "$MNT/etc/fstab"

  log "root UUID $root_uuid"
  log "boot UUID $boot_uuid"
  if [[ -e $MNT/usr/bin/qemu-riscv64-static ]]; then
    rm -f "$MNT/usr/bin/qemu-riscv64-static"
  fi
  printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' >"$MNT/etc/resolv.conf"
  sync
  umount "$MNT/dev/pts"
  umount "$MNT/dev"
  umount "$MNT/proc"
  umount "$MNT/sys"
  umount "$MNT/boot"
  umount "$MNT"
  detach_loop "$LOOP"
  LOOP=""

  if [[ ${SKIP_SHRINK:-0} != 1 ]]; then
    log "shrinking root filesystem and truncating the image"
    shrink_root_partition "$IMG" "$ROOT_SLACK_MIB"
  fi
  assert_gpt_layout "$IMG"
}

main() {
  require_build_tools
  WORK=$(mktemp -d /tmp/alpine-rv2-XXXXXX)
  mkdir -p "$OUT"
  assemble
  log "compressing image"
  xz -T0 -3 -f "$IMG"
  (
    cd "$OUT"
    sha256sum "$IMG_NAME.xz" >SHA256SUMS
  )
  BUILD_OK=1
  log "built $OUT/$IMG_NAME.xz"
  log "EXPERIMENTAL: SPI U-Boot must already be installed. Not verified on hardware."
}

main "$@"
