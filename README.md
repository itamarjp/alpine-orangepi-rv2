# Alpine Linux for Orange Pi RV2

Build-ready Alpine Linux **riscv64** microSD images for the **Orange Pi RV2**, reusing a precompiled vendor kernel instead of compiling one from source.

> **Status:** Experimental / work in progress. No bootable image has been published or verified yet.

## Goal

This repository will contain GitHub Actions workflows to assemble an Alpine Linux root filesystem, integrate the Orange Pi RV2 kernel and device trees, configure boot and networking, and publish a compressed `.img.xz` image with SHA256 checksums.

## Kernel assets

Upload a release asset named `kernel-6.6.63-ky-rv2.tar.xz` to the release tagged `kernel-6.6.63-ky`. The archive should preserve paths such as:

```text
boot/vmlinuz-6.6.63-ky
boot/dtb-6.6.63-ky/
lib/modules/6.6.63-ky/
lib/firmware/esos.elf
```

Check the actual source image paths before packaging. Verify redistributability of firmware and other vendor components before publishing them.

## Planned image build

1. Download and verify the pinned kernel archive from GitHub Releases.
2. Assemble Alpine Linux riscv64 rootfs.
3. Install matching kernel modules, DTBs and required firmware.
4. Configure OpenRC, SSH and Ethernet.
5. Prepare boot configuration compatible with the board's existing U-Boot.
6. Generate and validate a partitioned microSD image.
7. Publish the compressed image and checksum to GitHub Releases.

The U-Boot boot method, kernel filename, initramfs, device-tree selection and root device must be verified against the actual Orange Pi RV2 firmware before the image can be called bootable.

## References

- [Alpine Linux: Installing on OrangePi RV2](https://wiki.alpinelinux.org/wiki/Installing_Alpine_Linux_on_OrangePi_RV2)
- [Fedora RISC-V: OrangePi RV2](https://fedoraproject.org/wiki/Architectures/RISC-V/OrangePi/RV2)

## License

Licenses for Alpine packages, the Linux kernel and vendor firmware remain those of their respective upstream projects. No blanket license is asserted for third-party binaries.
