# Alpine RV2 build follow-up

The original image build workflow failed in the image construction step.
The detailed job logs were not available through the connected API.

## Required builder changes

- Pin minirootfs to `alpine-minirootfs-3.24.2-riscv64.tar.gz` from `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/riscv64/`.
- Keep APK repositories `https://dl-cdn.alpinelinux.org/alpine/edge/main` and `https://dl-cdn.alpinelinux.org/alpine/edge/community`.
- When downloading the `.sha256` file, validate the checksum against the downloaded local file name `rootfs.tar.gz`, not the upstream tarball name.
- Check vendor image SHA256, partition loop setup, bootloader and initramfs compatibility.

This branch is a diagnostic follow-up; the builder changes are not yet committed.
