#!/usr/bin/env bash
# Fast checks for the extlinux image builder. No vendor download and no qemu.
set -euo pipefail
export LC_ALL=C

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/image-lib.sh"

fail() {
  printf 'self-check failed: %s\n' "$*" >&2
  exit 1
}

log "syntax"
bash -n "$SCRIPT_DIR/build-image.sh"
bash -n "$SCRIPT_DIR/image-lib.sh"
bash -n "$SCRIPT_DIR/self-check.sh"
sh -n "$SCRIPT_DIR/rootfs/usr/local/sbin/rv2-grow-root"
python3 -m py_compile "$SCRIPT_DIR/patch-mkinitfs.py" "$SCRIPT_DIR/list-initramfs.py"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -x "$SCRIPT_DIR/build-image.sh" "$SCRIPT_DIR/image-lib.sh" "$SCRIPT_DIR/self-check.sh"
  shellcheck -s sh "$SCRIPT_DIR/rootfs/usr/local/sbin/rv2-grow-root"
fi

log "boot-model guards"
if grep -nE 'orangepiEnv|uInitrd|boot\.scr' "$SCRIPT_DIR/build-image.sh" | grep -v 'must not' | grep -v 'does not keep'; then
  fail "build-image.sh references the vendor boot path"
fi
grep -q 'write_extlinux' "$SCRIPT_DIR/build-image.sh"
grep -q 'mkinitfs-rv2' "$SCRIPT_DIR/build-image.sh"
grep -q 'PermitRootLogin yes' "$SCRIPT_DIR/rootfs/etc/ssh/sshd_config.d/10-rv2.conf"
grep -q 'root/alpine' "$SCRIPT_DIR/rootfs/etc/motd"
grep -q 'root/alpine' "$SCRIPT_DIR/rootfs/etc/issue"
grep -q 'disk="/dev/${diskname}"' "$SCRIPT_DIR/rootfs/usr/local/sbin/rv2-grow-root"

log "apk repositories"
repo_file=$SCRIPT_DIR/rootfs/etc/apk/repositories
diff -u <(printf '%s\n' \
  'https://dl-cdn.alpinelinux.org/alpine/v3.24/main' \
  'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' \
  '# https://dl-cdn.alpinelinux.org/alpine/edge/testing') "$repo_file" \
  || fail "expected Alpine v3.24 main and community only"
grep -Fq 'rootfs/etc/apk/repositories' "$SCRIPT_DIR/build-image.sh" \
  || fail "build must use the overlay repositories"

log "mkinitfs patch"
fake=$(mktemp -d)
mkdir -p "$fake/sbin" "$fake/etc/mkinitfs/features.d" "$fake/lib/firmware"
printf 'features="ata base ext4 mmc"\n' >"$fake/etc/mkinitfs/mkinitfs.conf"
printf '/bin/busybox\n' >"$fake/etc/mkinitfs/features.d/base.files"
printf 'regulatory\n' >"$fake/lib/firmware/regulatory.db"
cat >"$fake/sbin/mkinitfs" <<'EOF'
initfs_firmware() {
	rm -rf "$tmpdir"/lib/firmware
	mkdir -p "$tmpdir"/lib/firmware
	return 0
}
EOF
python3 "$SCRIPT_DIR/patch-mkinitfs.py" "$fake"
grep -qx '/lib/firmware/esos.elf' "$fake/etc/mkinitfs/features.d/base.files"
grep -qx '/lib/firmware/regulatory.*' "$fake/etc/mkinitfs/features.d/base.files"
grep -q 'custom_files=' "$fake/etc/mkinitfs/mkinitfs.conf"
grep -q '#rm -rf "\$tmpdir"/lib/firmware' "$fake/sbin/mkinitfs-rv2"
grep -q '\[ ! -d "\$tmpdir"/lib/firmware \] && mkdir -p' "$fake/sbin/mkinitfs-rv2"
grep -q 'rm -rf "\$tmpdir"/lib/firmware' "$fake/sbin/mkinitfs"
rm -rf "$fake"

log "kernel asset copy ignores vendor boot files"
src=$(mktemp -d)
dst=$(mktemp -d)
mkdir -p "$src/boot/dtb-6.6.63-ky/ky" "$src/lib/modules/6.6.63-ky" "$src/lib/firmware"
echo vmlinuz >"$src/boot/vmlinuz-6.6.63-ky"
echo map >"$src/boot/System.map-6.6.63-ky"
echo cfg >"$src/boot/config-6.6.63-ky"
echo dtb >"$src/boot/dtb-6.6.63-ky/ky/x1_orangepi-rv2.dtb"
echo mod >"$src/lib/modules/6.6.63-ky/modules.dep"
echo esos >"$src/lib/firmware/esos.elf"
echo scr >"$src/boot/boot.scr"
echo env >"$src/boot/orangepiEnv.txt"
echo uinit >"$src/boot/uInitrd"
ln -s vmlinuz-6.6.63-ky "$src/boot/Image"
copy_kernel_assets "$src" "$dst"
[[ -f $dst/boot/vmlinuz-6.6.63-ky ]]
[[ -f $dst/boot/dtb-6.6.63-ky/ky/x1_orangepi-rv2.dtb ]]
[[ -f $dst/lib/firmware/esos.elf ]]
[[ ! -e $dst/boot/boot.scr ]]
[[ ! -e $dst/boot/orangepiEnv.txt ]]
[[ ! -e $dst/boot/uInitrd ]]
[[ ! -e $dst/boot/Image ]]
rm -rf "$src" "$dst"

log "extlinux text"
ext=$(mktemp)
write_extlinux "$ext" "236a5824-0390-42dc-83e3-f02123188f96"
assert_extlinux_file "$ext" "236a5824-0390-42dc-83e3-f02123188f96"
rm -f "$ext"

log "initramfs esos append"
initdir=$(mktemp -d)
mkdir -p "$initdir/src/bin"
echo busybox >"$initdir/src/bin/sh"
(
  cd "$initdir/src"
  find . -print | cpio -o -H newc | gzip -c >"$initdir/initramfs"
)
echo esos >"$initdir/esos.elf"
if initramfs_has_esos "$initdir/initramfs"; then
  fail "fixture initramfs unexpectedly contained esos.elf"
fi
ensure_esos_in_initramfs "$initdir/initramfs" "$initdir/esos.elf"
initramfs_has_esos "$initdir/initramfs"
rm -rf "$initdir"

log "first-boot grow script"
grow_case() {
  local rootdev=$1 fstype=$2 partno=$3 pkname=$4 grow_rc=$5 grow_out=$6 expect=$7
  local dir=$ROOT/scripts/rootfs/usr/local/sbin/rv2-grow-root
  local bin marker logf
  bin=$(mktemp -d)
  marker=$(mktemp)
  rm -f "$marker"
  logf=$bin/grow.log
  cat >"$bin/findmnt" <<EOF
#!/bin/sh
case "\$2 \$3" in
  "-o SOURCE") printf '%s\n' "$rootdev" ;;
  "-o FSTYPE") printf '%s\n' "$fstype" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$bin/readlink" <<EOF
#!/bin/sh
printf '%s\n' "$rootdev"
EOF
  cat >"$bin/lsblk" <<EOF
#!/bin/sh
case "\$3" in
  PARTN) printf '%s\n' "$partno" ;;
  PKNAME) printf '%s\n' "$pkname" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$bin/growpart" <<EOF
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >>"$logf"
printf '%s\n' "$grow_out"
exit $grow_rc
EOF
  cat >"$bin/resize2fs" <<EOF
#!/bin/sh
printf 'resize %s\n' "\$1" >>"$logf"
EOF
  chmod 755 "$bin/findmnt" "$bin/readlink" "$bin/lsblk" "$bin/growpart" "$bin/resize2fs"
  set +e
  PATH="$bin:$PATH" RV2_GROW_MARKER=$marker sh "$dir"
  local rc=$?
  set -e
  if [[ $expect == ok && $rc -ne 0 ]]; then
    fail "grow script failed for $rootdev"
  fi
  if [[ $expect == fail && $rc -eq 0 ]]; then
    fail "grow script should have refused $rootdev"
  fi
  if [[ $expect == ok ]]; then
    grep -qx "/dev/$pkname $partno" "$logf" || fail "growpart was not called with /dev/$pkname $partno"
    [[ -e $marker ]] || fail "marker was not written"
  else
    [[ ! -e $logf ]] || fail "growpart ran for a refused disk"
  fi
  rm -rf "$bin" "$marker"
}

grow_case /dev/mmcblk0p2 ext4 2 mmcblk0 0 CHANGED ok
grow_case /dev/mmcblk0p2 ext4 2 mmcblk0 1 "NOCHANGE: partition 2" ok
grow_case /dev/nvme0n1p2 ext4 2 nvme0n1 0 CHANGED ok
grow_case /dev/sda2 ext4 2 sda 0 CHANGED ok
grow_case /dev/mmcblk0p1 ext4 1 mmcblk0 0 CHANGED fail

log "GPT create, extlinux, and root shrink"
require_cmd parted sgdisk sfdisk partx losetup mkfs.ext4 blkid resize2fs e2fsck
work=$(mktemp -d /tmp/alpine-rv2-self-XXXXXX)
img=$work/tiny.img
cleanup_work() {
  set +e
  if [[ -n ${loop:-} ]]; then
    umount "$work/boot" 2>/dev/null || true
    umount "$work/root" 2>/dev/null || true
    losetup -d "$loop" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup_work EXIT
create_gpt_image "$img" 32 64
p1_before=$(sfdisk_part "$img" 1)
loop=$(attach_loop "$img" rw)
[[ -b ${loop}p1 && -b ${loop}p2 ]]
mkfs.ext4 -F -L boot "${loop}p1" >/dev/null
mkfs.ext4 -F -L root "${loop}p2" >/dev/null
root_uuid=$(blkid -s UUID -o value "${loop}p2")
mkdir -p "$work/boot" "$work/root"
mount "${loop}p1" "$work/boot"
mount "${loop}p2" "$work/root"
write_extlinux "$work/boot/extlinux/extlinux.conf" "$root_uuid"
echo keep >"$work/boot/vmlinuz-6.6.63-ky"
echo rootfile >"$work/root/keep.txt"
[[ ! -e $work/boot/boot.scr ]]
sync
umount "$work/boot"
umount "$work/root"
detach_loop "$loop"
loop=""
shrink_root_partition "$img" 8
p1_after=$(sfdisk_part "$img" 1)
[[ $p1_before == "$p1_after" ]] || fail "boot partition changed"
assert_gpt_layout "$img"
loop=$(attach_loop "$img" rw)
mkdir -p "$work/boot" "$work/root"
mount "${loop}p1" "$work/boot"
mount "${loop}p2" "$work/root"
assert_extlinux_file "$work/boot/extlinux/extlinux.conf" "$root_uuid"
[[ $(cat "$work/root/keep.txt") == rootfile ]]
[[ ! -e $work/boot/boot.scr ]]
parted -sm "$img" print | grep -q gpt
umount "$work/boot"
umount "$work/root"
detach_loop "$loop"
loop=""
trap - EXIT
rm -rf "$work"
log "self-check passed"
