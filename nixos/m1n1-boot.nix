# m1n1 on the ESP (docs/boot_linux/boot-chain.md).
#
# iBoot starts m1n1 stage 1, the custom boot object on the macostest volume,
# which chainloads m1n1/boot.bin from the ESP: stage 2, m1n1 + device tree +
# U-Boot (nixos/j614s-ssd.nix). This module installs stage 2 with the boot
# loader, so each switch or nixos-install writes the stage 2 that goes with
# its generation, as nixos-apple-silicon's boot-m1n1 module does.
#
# Stage 1 can only be changed from recoveryOS (kmutil, with the owner's
# password), never from a running system. So the install also writes the
# stage 1 this generation would use to the ESP, with a script that installs
# it from recoveryOS Terminal, and says when the stage 1 that booted is not
# that one. `m1n1-status` shows the whole chain.
#
# On the ESP, in m1n1/:
#   boot.bin              stage 2 (what stage 1 chainloads)
#   boot.bin.prev         the stage 2 it replaced, to copy back from recoveryOS
#   stage1.bin            stage 1 for this generation, stage1.version its tag
#   stage1-good.bin       the last stage 1 seen booting, stage1-good.version
#   stage1-install.sh     installs stage1.bin (or `good`) from recoveryOS
#   dev.bin               the debug m1n1, for going back to the USB proxy
{ config, lib, pkgs, ... }:

let
  cfg = config.boot.m1n1;
  extlinux = config.boot.loader.generic-extlinux-compatible;
  stage1Version = cfg.stage1.versionTag or "unknown";

  installScript = pkgs.writeText "stage1-install.sh" ''
    #!/bin/sh
    # Installs m1n1 stage 1 from this ESP as the custom boot object of the
    # macostest volume. In recoveryOS (hold the power button at startup,
    # Options), Terminal:
    #
    #   diskutil mount disk0s4                      (the ESP, NIXBOOT)
    #   sh /Volumes/NIXBOOT/m1n1/stage1-install.sh  (this generation's)
    #   sh /Volumes/NIXBOOT/m1n1/stage1-install.sh good
    #                                    (the last one seen booting)
    #
    # A second argument names the volume, for a renamed macostest:
    #   sh /Volumes/NIXBOOT/m1n1/stage1-install.sh new /Volumes/NixOS
    set -e
    dir=$(cd "$(dirname "$0")" && pwd)
    case "''${1:-new}" in
      new) bin=stage1.bin; tag=stage1.version ;;
      good) bin=stage1-good.bin; tag=stage1-good.version ;;
      *) echo "usage: sh $0 [new|good] [volume]"; exit 1 ;;
    esac
    [ -e "$dir/$bin" ] || { echo "no $bin on the ESP"; exit 1; }

    if [ -n "''${2:-}" ]; then
      volume=$2
    else
      volume=$(diskutil info -plist "$(bless --getboot)" | plutil -extract MountPoint raw -)
      case "$(basename "$volume" | tr '[:upper:]' '[:lower:]')" in
        macostest*) ;;
        *) echo "The startup disk is $volume, not macostest. Pass the volume: sh $0 ''${1:-new} /Volumes/<name>"; exit 1 ;;
      esac
    fi
    case "$volume" in
      *"Macintosh HD"*) echo "Refusing to touch $volume."; exit 1 ;;
    esac

    echo "m1n1 stage 1 $(cat "$dir/$tag") as the custom boot object of $volume."
    echo "Enter to continue, control-C to cancel."
    read _
    while ! kmutil configure-boot -c "$dir/$bin" --raw --entry-point 2048 --lowest-virtual-address 0 -v "$volume"; do
      echo "kmutil failed (password?). Enter to try again, control-C to stop."
      read _
    done
    echo "Installed. Reboot: shutdown -r now"
  '';

  # Reads what booted from the device tree m1n1 filled in and compares it
  # with the ESP. With --record (at boot and at each install) it keeps the
  # stage 1 that booted as stage1-good.bin when it is the one on the ESP.
  status = pkgs.writeShellApplication {
    name = "m1n1-status";
    runtimeInputs = [ pkgs.coreutils pkgs.diffutils ];
    text = ''
      chosen=/proc/device-tree/chosen
      prop() { if [ -r "$chosen/$1" ]; then tr -d '\0' < "$chosen/$1"; else echo "unknown"; fi; }
      esp() { if [ -r "/boot/m1n1/$1" ]; then cat "/boot/m1n1/$1"; else echo "none"; fi; }
      running=$(prop asahi,m1n1-stage1-version)
      onesp=$(esp stage1.version)

      if [ "''${1:-}" = "--record" ]; then
        if [ "$running" = "$onesp" ] && [ -e /boot/m1n1/stage1.bin ] \
          && ! cmp -s /boot/m1n1/stage1.bin /boot/m1n1/stage1-good.bin; then
          cp /boot/m1n1/stage1.bin /boot/m1n1/stage1-good.bin.new
          sync -f /boot/m1n1/stage1-good.bin.new
          mv /boot/m1n1/stage1-good.bin.new /boot/m1n1/stage1-good.bin
          cp /boot/m1n1/stage1.version /boot/m1n1/stage1-good.version
        fi
        if [ "$running" != "$onesp" ] && [ "$onesp" != "none" ]; then
          echo "m1n1 stage 1: booted $running, this generation's is $onesp."
          echo "  To update it: recoveryOS Terminal, sh /Volumes/NIXBOOT/m1n1/stage1-install.sh"
          echo "  (README, Boot chain updates). Nothing is wrong until then."
        fi
        exit 0
      fi

      echo "iBoot               $(prop asahi,iboot1-version) / $(prop asahi,iboot2-version)"
      echo "m1n1 stage 1        booted $running"
      echo "                    on the ESP $onesp (stage1.bin), last good $(esp stage1-good.version)"
      echo "m1n1 stage 2        booted $(prop asahi,m1n1-stage2-version)"
      echo "U-Boot              booted $(prop u-boot,version)"
      echo "kernel              booted $(uname -r)"
      if [ "$running" != "$onesp" ]; then
        echo
        echo "Stage 1 differs from this generation's. To update it, in recoveryOS Terminal:"
        echo "  diskutil mount disk0s4 && sh /Volumes/NIXBOOT/m1n1/stage1-install.sh"
      fi
    '';
  };
in
{
  options.boot.m1n1 = {
    stage2 = lib.mkOption {
      type = lib.types.path;
      description = "The file installed as /boot/m1n1/boot.bin.";
    };
    devStage2 = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Installed as /boot/m1n1/dev.bin, to copy over boot.bin for the USB proxy.";
    };
    stage1 = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The release m1n1 (pkgs/m1n1.nix) for stage 1. Its config lines name
        the ESP by the PARTUUID of /boot, read at install time.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = extlinux.enable;
        message = "nixos/m1n1-boot.nix extends the generic-extlinux-compatible boot loader";
      }
    ];

    environment.systemPackages = [ status ];

    # At each boot: keep the stage 1 that booted if it is the ESP's, and
    # log when it is not.
    systemd.services.m1n1-status = {
      description = "Record which m1n1 stage 1 booted";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = "/boot";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${status}/bin/m1n1-status --record";
      };
    };

    # The extlinux installer, then stage 2 (and stage 1): each written beside
    # the old file and renamed over it, so a failed copy leaves the previous
    # file whole. Stage 2 is one file for all generations, so the one it
    # replaces is kept as boot.bin.prev for recoveryOS to copy back.
    system.build.installBootLoader = lib.mkForce (
      pkgs.writeShellScript "install-extlinux-m1n1" ''
        set -eu
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils pkgs.util-linux ]}:$PATH
        ${extlinux.populateCmd} -d /boot -c "$@"

        put() { # put SRC DEST: replace DEST only if it differs
          if ! cmp -s "$1" "$2"; then
            install -D -m 644 "$1" "$2.new"
            sync -f "$2.new"
            mv "$2.new" "$2"
          fi
        }

        if [ -e /boot/m1n1/boot.bin ] && ! cmp -s /boot/m1n1/boot.bin ${cfg.stage2}; then
          put /boot/m1n1/boot.bin /boot/m1n1/boot.bin.prev
        fi
        put ${cfg.stage2} /boot/m1n1/boot.bin
        ${lib.optionalString (cfg.devStage2 != null) ''
          put ${cfg.devStage2} /boot/m1n1/dev.bin
        ''}
        ${lib.optionalString (cfg.stage1 != null) ''
          partuuid=$(findmnt -no PARTUUID /boot || true)
          if [ -n "$partuuid" ]; then
            tmp=$(mktemp)
            ${pkgs.runtimeShell} ${../pkgs/make-stage1.sh} ${cfg.stage1}/lib/m1n1/m1n1.bin "$partuuid" "$tmp"
            put "$tmp" /boot/m1n1/stage1.bin
            rm -f "$tmp"
            echo ${stage1Version} > /boot/m1n1/stage1.version
            put ${installScript} /boot/m1n1/stage1-install.sh
          else
            echo "m1n1 stage 1 not written: no PARTUUID for /boot" >&2
          fi
          ${status}/bin/m1n1-status --record
        ''}
      ''
    );
  };
}
