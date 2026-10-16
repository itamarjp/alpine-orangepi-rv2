#!/usr/bin/env bash
# Shared helpers for the Orange Pi RV2 Alpine image.
# Boot model: manufacturer OpenSBI/U-Boot in SPI loads extlinux from a GPT boot partition.
# shellcheck shell=bash

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*" >&2
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

IMAGE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KVER_DEFAULT="6.6.63-ky"
DTB_REL="dtb-${KVER_DEFAULT}/ky/x1_orangepi-rv2.dtb"

create_gpt_image() {
  local img=$1 boot_mib=$2 root_mib=$3
  local boot_end total
  boot_end=$((1 + boot_mib))
  total=$((boot_end + root_mib + 2))
  rm -f "$img"
  truncate -s "${total}M" "$img"
  parted -s -a optimal "$img" mklabel gpt
  parted -s -a optimal "$img" mkpart boot ext4 1MiB "${boot_end}MiB"
  parted -s "$img" set 1 boot on
  parted -s -a optimal "$img" mkpart root ext4 "${boot_end}MiB" 100%
  assert_gpt_layout "$img"
}

assert_gpt_layout() {
  local img=$1
  local count flags label
  label=$(parted -sm "$img" print | awk -F: 'NR == 2 { print $6 }')
  [[ $label == gpt ]] || die "disk label is '$label', expected gpt ($img)"
  count=$(parted -sm "$img" print | awk -F: 'NR > 2 && $1 ~ /^[0-9]+$/ { n++ } END { print n + 0 }')
  [[ $count -eq 2 ]] || die "expected 2 partitions, found $count"
  flags=$(parted -sm "$img" print | awk -F: '$1 == "1" { print $7 }')
  [[ $flags == *boot* ]] || die "partition 1 is missing the boot flag ($flags)"
}

attach_loop() {
  local img=$1 mode=${2:-rw}
  local -a args=(--find --show --partscan)
  local loop
  if [[ $mode == ro ]]; then
    args+=(--read-only)
  fi
  loop=$(losetup "${args[@]}" "$img")
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [[ -b ${loop}p1 ]]; then
      printf '%s\n' "$loop"
      return 0
    fi
    partx -u "$loop" >/dev/null 2>&1 || partx -av "$loop" >/dev/null 2>&1 || true
    sleep 0.2
  done
  die "partition nodes did not appear for $loop"
}

detach_loop() {
  local loop=$1
  [[ -n $loop ]] || return 0
  losetup -d "$loop" 2>/dev/null || true
}

e2fsck_fix() {
  local dev=$1 rc=0
  e2fsck -f -y "$dev" || rc=$?
  if [[ $rc -gt 1 ]]; then
    die "e2fsck $dev failed with status $rc"
  fi
}

dumpe2fs_field() {
  local dev=$1 label=$2 value
  value=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F: -v l="$label" '$1 == l { gsub(/ /, "", $2); print $2; exit }')
  [[ -n $value ]] || die "dumpe2fs field '$label' missing on $dev"
  printf '%s\n' "$value"
}

sfdisk_part() {
  local img=$1 number=$2
  sfdisk -J "$img" | python3 -c 'import json,sys
n=int(sys.argv[1])
pt=json.load(sys.stdin)["partitiontable"]
parts=pt["partitions"]
if len(parts) < n:
    raise SystemExit("partition %s missing" % n)
part=parts[n-1]
print(part["start"], part["size"])
' "$number"
}

write_extlinux() {
  local dest=$1 root_uuid=$2
  [[ $root_uuid =~ ^[0-9a-fA-F-]+$ ]] || die "refusing to write extlinux with root UUID '$root_uuid'"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
default l0
menu title Alpine U-Boot menu
prompt 1
timeout 10

label l0
 menu label Alpine Linux (Kernel ${KVER_DEFAULT})
 linux /vmlinuz-${KVER_DEFAULT}
 initrd /initramfs-${KVER_DEFAULT}
 fdt /${DTB_REL}
 append mtdparts=d420c000.spi-0:64K@0(bootinfo),64K@64K(private),256K@128K(fsbl),64K@384K(env),192K@448K(opensbi),-@640K(uboot) root=UUID=${root_uuid} console=ttyS0,115200 console=tty1 rootwait rw rootfstype=ext4 earlycon=sbi
EOF
}

assert_extlinux_file() {
  local file=$1 root_uuid=$2
  [[ -f $file ]] || die "missing $file"
  grep -q '^default l0$' "$file" || die "extlinux missing default"
  grep -q "^ linux /vmlinuz-${KVER_DEFAULT}$" "$file" || die "extlinux kernel path"
  grep -q "^ initrd /initramfs-${KVER_DEFAULT}$" "$file" || die "extlinux initrd path"
  grep -q "^ fdt /${DTB_REL}$" "$file" || die "extlinux fdt path"
  grep -q "root=UUID=${root_uuid}" "$file" || die "extlinux root UUID"
  grep -q 'console=ttyS0,115200 console=tty1 rootwait rw rootfstype=ext4 earlycon=sbi' "$file" || die "extlinux append"
  grep -q 'mtdparts=d420c000.spi-0:' "$file" || die "extlinux mtdparts"
  if grep -E -q 'boot\.scr|uInitrd|orangepiEnv|rootdev=' "$file"; then
    die "extlinux contains a vendor boot path"
  fi
}

copy_kernel_assets() {
  local src=$1 dest=$2 kver=${3:-$KVER_DEFAULT}
  local f modsrc esos c banned
  mkdir -p "$dest/boot/extlinux" "$dest/lib/modules" "$dest/lib/firmware"
  for f in "vmlinuz-$kver" "System.map-$kver" "config-$kver"; do
    [[ -f $src/boot/$f ]] || die "vendor tree missing boot/$f"
    cp -a "$src/boot/$f" "$dest/boot/$f"
  done
  [[ -d $src/boot/dtb-$kver ]] || die "vendor tree missing boot/dtb-$kver"
  rm -rf "$dest/boot/dtb-$kver"
  cp -a "$src/boot/dtb-$kver" "$dest/boot/dtb-$kver"
  [[ -f $dest/boot/dtb-$kver/ky/x1_orangepi-rv2.dtb ]] || die "missing x1_orangepi-rv2.dtb"
  if [[ -d $src/lib/modules/$kver ]]; then
    modsrc=$src/lib/modules/$kver
  elif [[ -d $src/usr/lib/modules/$kver ]]; then
    modsrc=$src/usr/lib/modules/$kver
  else
    die "vendor tree missing modules $kver"
  fi
  rm -rf "$dest/lib/modules/$kver"
  cp -a "$modsrc" "$dest/lib/modules/$kver"
  esos=""
  for c in "$src/lib/firmware/esos.elf" "$src/usr/lib/firmware/esos.elf"; do
    if [[ -f $c ]]; then
      esos=$c
      break
    fi
  done
  if [[ -z $esos ]]; then
    esos=$(find "$src" -name esos.elf -type f -print -quit)
  fi
  [[ -n $esos && -f $esos ]] || die "esos.elf not found in vendor tree"
  cp -a "$esos" "$dest/lib/firmware/esos.elf"
  for banned in boot.scr boot.cmd uInitrd orangepiEnv.txt Image initrd.img; do
    if [[ -e $dest/boot/$banned || -L $dest/boot/$banned ]]; then
      die "vendor boot file leaked into the Alpine tree: $banned"
    fi
  done
  if find "$dest/boot" -maxdepth 1 \( -name 'uInitrd*' -o -name 'boot.scr' -o -name 'orangepiEnv.txt' \) -print -quit | grep -q .; then
    die "vendor boot file leaked into the Alpine boot directory"
  fi
}

initramfs_compression() {
  local img=$1
  if gzip -t "$img" 2>/dev/null; then
    printf 'gzip\n'
  elif xz -t "$img" 2>/dev/null; then
    printf 'xz\n'
  elif command -v zstd >/dev/null 2>&1 && zstd -t "$img" 2>/dev/null; then
    printf 'zstd\n'
  elif command -v lz4 >/dev/null 2>&1 && lz4 -t "$img" 2>/dev/null; then
    printf 'lz4\n'
  else
    printf 'raw\n'
  fi
}

decompress_initramfs() {
  local img=$1
  case $(initramfs_compression "$img") in
    gzip) gzip -dc "$img" ;;
    xz) xz -dc "$img" ;;
    zstd) zstd -dc "$img" ;;
    lz4) lz4 -dc "$img" ;;
    raw) cat "$img" ;;
    *) die "unknown initramfs compression" ;;
  esac
}

list_initramfs() {
  decompress_initramfs "$1" | python3 "$IMAGE_LIB_DIR/list-initramfs.py"
}

initramfs_has_esos() {
  local listing
  listing=$(list_initramfs "$1") || return 1
  printf '%s\n' "$listing" | grep -qE '(^|/)(usr/)?lib/firmware/esos\.elf$'
}

ensure_esos_in_initramfs() {
  local img=$1 esos=$2 tmp comp
  [[ -f $img ]] || die "initramfs missing: $img"
  [[ -f $esos ]] || die "esos.elf missing: $esos"
  if initramfs_has_esos "$img"; then
    log "initramfs already contains esos.elf"
    return 0
  fi
  log "mkinitfs output lacked esos.elf; appending a firmware cpio archive"
  tmp=$(mktemp -d)
  comp=$(initramfs_compression "$img")
  decompress_initramfs "$img" >"$tmp/base.cpio"
  mkdir -p "$tmp/extra/lib/firmware"
  cp -a "$esos" "$tmp/extra/lib/firmware/esos.elf"
  (
    cd "$tmp/extra" || exit 1
    find . -print | sort | cpio -o -H newc
  ) >>"$tmp/base.cpio"
  case $comp in
    gzip) gzip -c "$tmp/base.cpio" >"$img" ;;
    xz) xz -c "$tmp/base.cpio" >"$img" ;;
    zstd) zstd -c "$tmp/base.cpio" >"$img" ;;
    lz4) lz4 -c "$tmp/base.cpio" >"$img" ;;
    raw) cp "$tmp/base.cpio" "$img" ;;
    *) die "cannot recompress $comp" ;;
  esac
  rm -rf "$tmp"
  initramfs_has_esos "$img" || die "esos.elf still missing from $img"
}

shrink_root_partition() {
  local img=$1 slack_mib=${2:-256}
  local loop rootdev blocks block_size slack_blocks target fs_bytes
  local start current_size new_sectors p1_before p1_after final_sectors
  loop=$(attach_loop "$img" rw)
  for _ in {1..15}; do
    [[ -b ${loop}p2 ]] && break
    partx -u "$loop" >/dev/null 2>&1 || partx -av "$loop" >/dev/null 2>&1 || true
    sleep 0.2
  done
  [[ -b ${loop}p2 ]] || die "root partition node missing on $loop"
  rootdev=${loop}p2
  p1_before=$(sfdisk_part "$img" 1)
  e2fsck_fix "$rootdev"
  resize2fs -M "$rootdev"
  e2fsck_fix "$rootdev"
  blocks=$(dumpe2fs_field "$rootdev" "Block count")
  block_size=$(dumpe2fs_field "$rootdev" "Block size")
  slack_blocks=$((slack_mib * 1024 * 1024 / block_size))
  target=$((blocks + slack_blocks))
  resize2fs "$rootdev" "$target"
  e2fsck_fix "$rootdev"
  blocks=$(dumpe2fs_field "$rootdev" "Block count")
  block_size=$(dumpe2fs_field "$rootdev" "Block size")
  fs_bytes=$((blocks * block_size))
  # Keep 4 MiB after the filesystem so a one-sector rounding error cannot clip it.
  new_sectors=$(((fs_bytes + 4 * 1024 * 1024 + 511) / 512))
  new_sectors=$(((new_sectors + 2047) / 2048 * 2048))
  read -r start current_size <<<"$(sfdisk_part "$img" 2)"
  detach_loop "$loop"
  loop=""
  if ((new_sectors + 4096 >= current_size)); then
    log "root partition left at ${current_size} sectors (shrink would not help)"
    return 0
  fi
  log "shrinking root partition from ${current_size} to ${new_sectors} sectors"
  printf '%s,%s\n' "$start" "$new_sectors" | sfdisk --no-reread --no-tell-kernel -N 2 "$img"
  final_sectors=$((start + new_sectors + 2048))
  truncate -s $((final_sectors * 512)) "$img"
  sgdisk -e "$img"
  parted -s "$img" name 1 boot
  parted -s "$img" name 2 root
  parted -s "$img" set 1 boot on
  sgdisk -v "$img"
  assert_gpt_layout "$img"
  p1_after=$(sfdisk_part "$img" 1)
  [[ $p1_before == "$p1_after" ]] || die "boot partition changed during shrink ($p1_before -> $p1_after)"
  loop=$(attach_loop "$img" rw)
  e2fsck_fix "${loop}p2"
  detach_loop "$loop"
}
