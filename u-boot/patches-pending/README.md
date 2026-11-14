# Pending U-Boot patches

Not built (pkgs/u-boot.nix applies only u-boot/patches).

- `0002-rtkit-helper-multi-cell-iommus.patch` starts the internal keyboard in
  U-Boot and hands the running MTP to Linux, which kernel patch 0032 adopts.
  Tested on 2026-11-14: Linux adopts the session and keyboard and trackpad
  work, and with quiet boot off (pkgs/u-boot.nix) the keyboard works in the
  extlinux menu. But iBoot panicked (3bdace14b1a9a68:2081, loading the boot object) on 3 of
  5 reboots through this U-Boot, against 0 of 3 with it removed. Move it
  back to u-boot/patches once that is understood.
