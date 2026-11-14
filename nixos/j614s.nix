# The J614s (MacBook Pro 14", M4 Pro): what any NixOS on this machine needs,
# exported as nixosModules.default (nixos/j614s-ssd.nix adds the SSD layout
# and the boot chain). The kernel and its command line, the initrd, the
# Apple firmware, the console font, and the debug-USB console.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.j614s;
in
{
  options.hardware.j614s.debugConsole.autologinRoot = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Log root in by itself on the dockchannel console (ttyDC0), which a host
      reaches over debug USB with a cable on the left USB-C port. The
      nixos-m4pro tools (tools/m4sh, just update) drive the machine through it.
      Root stays locked everywhere else.
    '';
  };

  options.hardware.j614s.sources = lib.mkOption {
    type = lib.types.submodule {
      options = lib.genAttrs [ "m1n1" "uBoot" "linux" ] (name: lib.mkOption {
        # A flake input (its shortRev names the build) or a path.
        type = lib.types.raw;
        description = "The ${name} source tree; the patches in this repository apply on top.";
      });
    };
    description = ''
      The sources of m1n1, U-Boot and the kernel. The modules this flake
      exports set them from its locked inputs (flake.nix, `sources`).
    '';
  };

  config = {
    nixpkgs.hostPlatform = "aarch64-linux";

    boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./kernel.nix { src = config.hardware.j614s.sources.linux; });

    # The drivers this machine needs are built into the kernel.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.availableKernelModules = lib.mkForce [ ];
    boot.initrd.kernelModules = lib.mkForce [ ];
    boot.kernelModules = lib.mkForce [ ];
    boot.extraModulePackages = lib.mkForce [ ];

    boot.loader.grub.enable = false;

    # Only critical kernel messages on the consoles. brcmfmac logs an error
    # on every Wi-Fi connect (the firmware refuses join_pref, -52) and at
    # start-up (P2P), which landed on the greeter. All of it stays in dmesg
    # and the journal.
    boot.consoleLogLevel = lib.mkDefault 3;

    # Consoles: the internal screen and the dockchannel UART the host sees
    # over debug USB. The last console= is /dev/console.
    boot.kernelParams = [
      "earlycon"
      "console=tty0"
      "console=ttyDC0"
      "cpuidle.off=1"
      # M4 cores lose their registers on WFI and WFIT (iBoot locks CYC_OVRD,
      # which on M1-M3 keeps WFI retentive). Kernel patch 0024 saves them
      # around the idle WFI, so cores idle instead of spinning; timed waits
      # (WFIT in udelay) stay off. m1n1's kboot appends idle=nop
      # arm64.nowfxt itself, but U-Boot replaces the command line with the
      # extlinux APPEND, so this one must be ours.
      "arm64.nowfxt"
    ];

    # Apple firmware (trackpad, Wi-Fi, Bluetooth): a fixed-output path, so
    # every configuration finds the same one (pkgs/j614s-firmware.nix). The
    # kernel loads firmware uncompressed (no FW_LOADER_COMPRESS).
    hardware.firmware = [ (pkgs.callPackage ../pkgs/j614s-firmware.nix { }) ];
    hardware.firmwareCompression = "none";
    # The trackpad, Wi-Fi and Bluetooth ask for their firmware as soon as
    # they probe, while the initrd still runs.
    boot.initrd.extraFirmwarePaths = [
      "apple/tpmtfw-j614s.bin"
      "brcm/brcmfmac4388c2-pcie.apple,mriya-WLMT-a.txt"
      "brcm/brcmfmac4388c2-pcie.apple,mriya-WLMT-u.txt"
      "brcm/brcmfmac4388c2-pcie.apple,mriya.bin"
      "brcm/brcmfmac4388c2-pcie.apple,mriya.clm_blob"
      "brcm/brcmfmac4388c2-pcie.apple,mriya.sig"
      "brcm/brcmfmac4388c2-pcie.apple,mriya.txcap_blob"
      "brcm/brcmbt4388c2-apple,mriya-a.bin"
      "brcm/brcmbt4388c2-apple,mriya-a.ptb"
      "brcm/brcmbt4388c2-apple,mriya-u.bin"
      "brcm/brcmbt4388c2-apple,mriya-u.ptb"
    ];

    # A large console font for the 3024x1890 panel (Terminus 32 px), set
    # from the initrd on.
    console = {
      earlySetup = lib.mkDefault true;
      packages = [ pkgs.terminus_font ];
      font = lib.mkDefault "ter-v32n";
    };

    # Wi-Fi needs a manager to be usable; NetworkManager by default.
    networking.networkmanager.enable = lib.mkDefault true;
    # The kernel has no netfilter yet: no firewall until nftables is in.
    networking.firewall.enable = lib.mkDefault false;

    users.users.root.hashedPassword = lib.mkDefault "!";
    systemd.services."serial-getty@ttyDC0" = lib.mkIf cfg.debugConsole.autologinRoot {
      # A drop-in on systemd's serial-getty@ template, which keeps its TTY
      # settings; only the agetty line changes (NixOS's, plus --autologin).
      overrideStrategy = "asDropin";
      wantedBy = [ "getty.target" ];
      serviceConfig.ExecStart = [
        ""
        "${pkgs.util-linux}/bin/agetty --login-program ${config.services.getty.loginProgram} --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM"
      ];
    };
  };
}
