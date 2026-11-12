#!/bin/sh
# Pack the BusyBox initramfs (docs/boot_linux/checklist.md, item 5).
# Runs inside nixos-m4pro-builder through tools/kernel-env.sh:
#   docker exec nixos-m4pro-builder /work/tools/kernel-env.sh /work/tools/build-initramfs.sh
set -e
NP=github:NixOS/nixpkgs/177d0540942fb205af6993b1d5fa0b57799e09f8
busybox=$(nix build --no-link --print-out-paths "$NP#pkgsStatic.busybox")/bin/busybox
out=${OUT:-/src/out}
root=$(mktemp -d)
mkdir -p "$root/bin" "$out"
cp "$busybox" "$root/bin/busybox"
cp /work/initramfs/init "$root/init"
chmod 755 "$root/init" "$root/bin/busybox"
ln -s busybox "$root/bin/sh"
# Firmware extracted from macOS (not in git): build/firmware/apple/*.bin.
# The kernel's firmware loader reads /lib/firmware.
if [ -d /work/build/firmware ]; then
  mkdir -p "$root/lib"
  cp -r /work/build/firmware "$root/lib/firmware"
fi
(cd "$root" && find . | cpio -o -H newc --owner 0:0 2>/dev/null) | gzip -9 > "$out/initramfs.cpio.gz"
rm -rf "$root"
ls -l "$out/initramfs.cpio.gz"
