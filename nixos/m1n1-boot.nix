# m1n1 stage 2 on the ESP (docs/boot_linux/boot-chain.md).
#
# m1n1 stage 1, the boot object on the macostest volume, has one config line,
# chainload=<ESP PARTUUID>;m1n1/boot.bin (flake package m1n1-stage1). This
# module installs that file with the boot loader, so each generation's
# switch or nixos-install writes the stage 2 that goes with it, as
# nixos-apple-silicon's boot-m1n1 module does.
#
# Stage 2 is m1n1 + device tree + U-Boot (nixos/disk.nix). The debug m1n1
# goes beside it as m1n1/dev.bin, for going back to the USB proxy.
{ config, lib, pkgs, ... }:

let
  cfg = config.boot.m1n1;
  extlinux = config.boot.loader.generic-extlinux-compatible;
in
{
  options.boot.m1n1.stage2 = lib.mkOption {
    type = lib.types.path;
    description = "The file installed as /boot/m1n1/boot.bin.";
  };
  options.boot.m1n1.devStage2 = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = "Installed as /boot/m1n1/dev.bin, to copy over boot.bin for the USB proxy.";
  };

  config = {
    assertions = [
      {
        assertion = extlinux.enable;
        message = "nixos/m1n1-boot.nix extends the generic-extlinux-compatible boot loader";
      }
    ];

    # The extlinux installer, then the stage 2: written beside the old one
    # and renamed over it, so a failed copy leaves the previous file whole.
    system.build.installBootLoader = lib.mkForce (
      pkgs.writeShellScript "install-extlinux-m1n1" ''
        set -eu
        ${extlinux.populateCmd} -d /boot -c "$@"
        ${pkgs.coreutils}/bin/install -D -m 644 ${cfg.stage2} /boot/m1n1/boot.bin.new
        ${pkgs.coreutils}/bin/sync -f /boot/m1n1/boot.bin.new
        ${pkgs.coreutils}/bin/mv /boot/m1n1/boot.bin.new /boot/m1n1/boot.bin
        ${lib.optionalString (cfg.devStage2 != null) ''
          ${pkgs.coreutils}/bin/install -D -m 644 ${cfg.devStage2} /boot/m1n1/dev.bin
        ''}
      ''
    );
  };
}
