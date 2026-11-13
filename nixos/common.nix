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
    "clk_ignore_unused"
    "pd_ignore_unused"
    # M4 cores lose x0-x30 on WFI/WFIT (iBoot locks CYC_OVRD, which on M1-M3
    # keeps WFI retentive). m1n1's kboot appends these two itself, but
    # U-Boot replaces the command line with the extlinux APPEND, so they
    # must be ours: without them every secondary CPU crashes on its first
    # idle (pc 0, all registers zero).
    "idle=nop"
    "arm64.nowfxt"
  ];
  systemd.services."serial-getty@ttyDC0".enable = true;

  # A bring-up system: log in as root on both consoles without a password.
  services.getty.autologinUser = "root";
  # A shell in the initrd if stage 1 fails (root has no password here).
  boot.initrd.systemd.emergencyAccess = true;
  users.users.root.initialHashedPassword = "";

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
