# NixOS from RAM on the J614s (docs/boot_linux/checklist.md, item 15).
#
# The standard netboot image: the system closure in a squashfs inside the
# initrd, with a tmpfs overlay as root. It is booted the same way as the
# bring-up initramfs, through m1n1 from the host (tools/m4run), with
# init=${toplevel}/init on the command line.
#
# It is also the installer: the target has no network, so the closure of
# the installed system (disk.nix, passed in as diskSystem) is in this
# image's store, and m4pro-install (pkgs/m4pro-install.nix) partitions,
# formats and installs it.
{ config, lib, pkgs, modulesPath, diskSystem, ... }:

{
  imports = [
    (modulesPath + "/installer/netboot/netboot.nix")
    ./common.nix
  ];

  # The kernel's squashfs has zlib and xz, not zstd.
  netboot.squashfsCompression = "xz -Xdict-size 100%";

  # m4pro-install refers to diskSystem, so its whole closure is in this
  # image's store.
  environment.systemPackages = [
    (pkgs.callPackage ../pkgs/m4pro-install.nix {
      inherit diskSystem;
      inherit (config.system.build) nixos-install;
    })
  ];
}
