# Build notes

The rootfs-swap experiment is retired. That builder copied the vendor Ubuntu disk, reformatted its only Linux partition, and kept `boot.scr`, `uInitrd`, and `orangepiEnv.txt`.

The current builder creates a new GPT disk:

- Partition 1, about 512 MiB ext4, flagged boot, holds extlinux, the vendor kernel, the DTB, and an Alpine initramfs.
- Partition 2, ext4, holds Alpine.

Boot depends on manufacturer OpenSBI and U-Boot already programmed in SPI. This repository does not flash SPI. See `README.md` for the build, the flash command, and the credential policy.
