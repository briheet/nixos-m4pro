# What every NixOS system on the J614s shares: the kernel, its command line,
# the consoles, and the bring-up settings. ram.nix (netboot, from RAM) and
# disk.nix (installed on the internal SSD) import it.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];

  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "26.05";
  networking.hostName = "m4pro";

  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.callPackage ./kernel.nix { });

  # The drivers this machine needs are built into the kernel.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = lib.mkForce [ ];
  boot.initrd.kernelModules = lib.mkForce [ ];
  boot.kernelModules = lib.mkForce [ ];
  boot.extraModulePackages = lib.mkForce [ ];

  boot.loader.grub.enable = false;

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

  # Logins. The screen asks for a password. Root is locked, but logs in by
  # itself on the debug-USB console (ttyDC0): reaching it takes the cable to
  # the host, and tools/m4sh drives the machine through it.
  users.users.briheet = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "input" ];
    # No password in this (public) repo: `just set-password briheet` sets
    # one from the host, sending only its hash.
  };
  users.users.root.hashedPassword = "!";
  systemd.services."serial-getty@ttyDC0" = {
    # A drop-in on systemd's serial-getty@ template, which keeps its TTY
    # settings; only the agetty line changes (NixOS's, plus --autologin).
    overrideStrategy = "asDropin";
    wantedBy = [ "getty.target" ];
    serviceConfig.ExecStart = [
      ""
      "${pkgs.util-linux}/bin/agetty --login-program ${config.services.getty.loginProgram} --autologin root --noclear --keep-baud %I 115200,38400,9600 $TERM"
    ];
  };

  # No network device yet (Wi-Fi needs PCIe), and the kernel has no
  # netfilter. Turn the firewall back on with the network and nftables.
  networking.firewall.enable = false;
  networking.dhcpcd.enable = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Everything reaches this Mac over the debug USB link at about 400 KiB/s
  # until it has a network, so leave out the nixpkgs source (217 MB, for
  # NIX_PATH and the flake registry) and nixos-rebuild-ng (Python, 147 MB).
  # Systems are built on the host; nixos-install is added where needed.
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  system.disableInstallerTools = true;
}
