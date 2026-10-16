# Alpine Linux for Orange Pi RV2

Experimental **riscv64** disk image for the Orange Pi RV2. The image is built from a pinned Alpine minirootfs plus the vendor **6.6.63-ky** kernel. It is a new GPT disk. It does not clone the Ubuntu image.

> **Status:** Experimental. The boot path follows the [Alpine wiki](https://wiki.alpinelinux.org/wiki/Installing_Alpine_Linux_on_OrangePi_RV2) and has been verified on an Orange Pi RV2. New builds still require validation.

## Boot model

Manufacturer OpenSBI and U-Boot must already be in **SPI flash**. That stock bootloader looks for `/extlinux/extlinux.conf` on the boot partition. UART is 115200 8N1 on `ttyS0`.

This image:

- does **not** program SPI, and does not include a bootloader
- does **not** boot through `boot.scr`, `orangepiEnv.txt`, or `uInitrd`
- does **not** depend on the 30 MiB reserved area at the start of the vendor Ubuntu image

The vendor Ubuntu archive is only a source of `vmlinuz-6.6.63-ky`, `dtb-6.6.63-ky`, kernel modules, and `esos.elf`.

Alpine's own kernels are not used. The wiki reports that they panic while mounting root because they cannot load `esos.elf` through the Ky/SpacemiT remoteproc driver. In the vendor 6.6.63-ky kernel, `x1-rproc` is built in, so `esos.elf` has to be on the root filesystem **and** inside the initramfs.

## Disk layout

| Partition | Size | Filesystem | Role |
| --- | --- | --- | --- |
| 1 `boot` | 128 MiB | ext4 | `extlinux/extlinux.conf`, `vmlinuz-6.6.63-ky`, `initramfs-6.6.63-ky`, `dtb-6.6.63-ky/ky/x1_orangepi-rv2.dtb` |
| 2 `root` | Shrunk ext4 filesystem plus 128 MiB of slack | ext4 | Alpine root, modules, `/lib/firmware/esos.elf` |

`parted` marks partition 1 boot. On GPT that also sets the ESP type, which matches the wiki. The partition is still ext4.

`extlinux.conf` loads the vendor kernel and the Alpine initramfs with:

```text
root=UUID=<root> console=ttyS0,115200 console=tty1 rootwait rw rootfstype=ext4 earlycon=sbi
```

plus the wiki `mtdparts=d420c000.spi-0:...` string. The root line is filled in at build time. On first boot, `rv2-grow-root` grows partition 2 (never partition 1) to fill the card, then runs `resize2fs`.

## Credentials

The image ships with the same default as the previous experimental builds:

- user: `root`
- password: `alpine`

SSH allows password login as root (`PermitRootLogin yes`). `/etc/motd` and `/etc/issue` warn about the public default password. Setting `ROOT_PASSWORD` when building overrides that password without displaying it in the login banners.

## What is configured

- Hostname `orangepi-rv2`
- OpenRC, including networking, sshd, and the one-shot root grow service
- DHCP on `eth0` and `eth1`
- `ttyS0` enabled in `/etc/inittab` at 115200
- `/etc/fstab` by UUID for `/` and `/boot`
- `mkinitfs` patched the way the wiki describes (`mkinitfs-rv2` keeps `/lib/firmware/esos.elf`)

## Repositories

| Piece | Pin |
| --- | --- |
| Minirootfs | `alpine-minirootfs-3.24.2-riscv64.tar.gz` |
| Minirootfs SHA256 | `57132e6e4f3a4ba9ffdf24e485513ce507e45471e7fd565aeed91c055cd63f7b` |
| Minirootfs URL | `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/` |
| Packages | Alpine **v3.24** `main` and `community` |

`/etc/apk/repositories` lists only these stable repositories. Package versions within v3.24 still move; the minirootfs tarball does not.

## Kernel asset

The builder downloads and checks:

- URL: `https://github.com/itamarjp/alpine-orangepi-rv2/releases/download/kernel-6.6.63-ky/Orangepirv2_1.0.0_ubuntu_noble_server_linux6.6.63.7z`
- SHA256: `edc1d18e83e9cb509eb12dbab162555269b8255f64636a33e0ca8fcd33d865af`

From the mounted vendor root it copies only:

```text
boot/vmlinuz-6.6.63-ky
boot/System.map-6.6.63-ky
boot/config-6.6.63-ky
boot/dtb-6.6.63-ky/
lib/modules/6.6.63-ky/
lib/firmware/esos.elf
```

Confirm that redistributing the kernel and `esos.elf` is acceptable before publishing a release. Wi-Fi and Bluetooth firmware from the vendor image is not copied. The wiki says Wi-Fi and Bluetooth do not work.

## Build

GitHub Actions (`.github/workflows/build-image.yml`) runs `scripts/self-check.sh`, then `scripts/build-image.sh`, on `ubuntu-24.04`. The publish workflow (`.github/workflows/publish-release.yml`) runs that same path and uploads `alpine-orangepi-rv2-riscv64.img.xz` and `SHA256SUMS`.

Locally, on Ubuntu 24.04:

```sh
sudo apt-get install -y p7zip-full qemu-user-static binfmt-support xz-utils \
  e2fsprogs util-linux fdisk parted gdisk curl python3 cpio shellcheck
sudo bash scripts/self-check.sh
sudo bash scripts/build-image.sh
```

The image build runs Alpine's package tools inside a riscv64 chroot. The script registers the `qemu-riscv64` binfmt interpreter when it is not already enabled, because a single `qemu-riscv64-static` process does not reliably execute the later riscv binaries `apk` starts.

`scripts/self-check.sh` does not download the vendor archive. It checks syntax, the mkinitfs patch, extlinux text, the first-boot grow script, GPT creation, and root shrinking.

## Flash

Verify the checksum, then write the image to the whole SD card, USB disk, or NVMe device. This does **not** update SPI.

```sh
sha256sum -c SHA256SUMS
xz -dc alpine-orangepi-rv2-riscv64.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Replace `/dev/sdX` with the target disk, not a partition. If SPI does not already contain the manufacturer OpenSBI and U-Boot, the board will not boot this image. Use the manufacturer procedure to program SPI. Nothing in this repository does that.

A 3.3 V USB-UART adapter at **115200 8N1** on the board UART (`ttyS0`) is the practical way to watch U-Boot and the first boot. Pin positions are in the Orange Pi RV2 manual.

## Known limits

- Boot tested on Orange Pi RV2 hardware; each new image revision still needs testing.
- Wi-Fi and Bluetooth do not work, per the Alpine wiki.
- Some kernels have framebuffer problems. The console line keeps both `ttyS0` and `tty1`; U-Boot tends to honor the right-most `console=`.
- Manufacturer tools are not included.
- Packages come from Alpine v3.24 main and community. Versions inside that release still move; the minirootfs tarball is pinned.
- The published root partition is shrunk. The first-boot service grows it only for ext4 on `mmcblk`, `nvme`, or `sd` devices, and it refuses to grow partition 1.

## License

Licenses for Alpine packages, the Linux kernel, and vendor firmware remain those of their respective upstream projects. No blanket license is asserted for third-party binaries.
