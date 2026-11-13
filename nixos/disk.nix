# NixOS installed on the J614s's internal SSD (docs/boot_linux/checklist.md,
# item 18), in the space freed next to the macOS APFS container:
#
#   p4  nixos-boot  512 MiB  FAT32 (EFI system partition type)
#   p5  nixos       the rest ext4
#
# Partitions are found by GPT partition label, so the numbers macOS or a
# later repartition give them do not matter.
#
# Until m1n1 boots it on its own, the kernel comes from the host
# (tools/tether-boot.py) with root= on the command line; the standard
# extlinux entry on /boot records the kernel, initrd, device tree and
# command line of each generation for the later boot chain.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./common.nix
    ./m1n1-boot.nix
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/nixos-boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  boot.loader.generic-extlinux-compatible.enable = true;
  hardware.deviceTree.name = "apple/t6040-j614s.dtb";

  boot.m1n1.stage2 = "${pkgs.callPackage ../pkgs/m1n1.nix { release = false; }}/lib/m1n1/m1n1.bin";
}
