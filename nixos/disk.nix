# NixOS installed on the J614s's internal SSD (docs/boot_linux/checklist.md,
# item 18), in the space freed next to the macOS APFS container:
#
#   p4  nixos-boot  512 MiB  FAT32 (EFI system partition type)
#   p5  nixos       the rest ext4
#
# Partitions are found by GPT partition label, so the numbers macOS or a
# later repartition give them do not matter.
#
# Boot chain (docs/boot_linux/boot-chain.md): m1n1 stage 1 on macostest
# chainloads m1n1/boot.bin from p4, which is m1n1 + the J614s device tree +
# U-Boot; U-Boot shows the extlinux menu of generations and boots one.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./common.nix
    ./m1n1-boot.nix
    ./desktop.nix
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
  # Linux gets the device tree m1n1 filled in (memory, CPUs, framebuffer,
  # carveouts), which U-Boot passes on, not the bare one from the
  # generation: as nixos-apple-silicon does.
  boot.loader.generic-extlinux-compatible.useGenerationDeviceTree = false;
  hardware.deviceTree.name = "apple/t6040-j614s.dtb";

  # Stage 2: release m1n1, the kernel's J614s device tree and U-Boot, as
  # the Asahi installer lays out boot.bin. The device tree is this
  # generation's kernel's, so stage 2 is rewritten with each generation.
  boot.m1n1.stage2 = pkgs.runCommand "m1n1-stage2.bin" { } ''
    cat ${pkgs.callPackage ../pkgs/m1n1.nix { }}/lib/m1n1/m1n1.bin \
      ${config.boot.kernelPackages.kernel}/dtbs/apple/t6040-j614s.dtb \
      ${pkgs.callPackage ../pkgs/u-boot.nix { }}/u-boot-nodtb.bin.gz > $out
  '';
  # The debug m1n1 (USB proxy) beside it: from U-Boot's prompt,
  # `just stage2-proxy` copies it over boot.bin for tethered work.
  boot.m1n1.devStage2 = "${pkgs.callPackage ../pkgs/m1n1.nix { release = false; }}/lib/m1n1/m1n1.bin";
}
