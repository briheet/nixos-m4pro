# NixOS from RAM on the J614s (docs/boot_linux/checklist.md, item 15).
#
# The standard netboot image: the system closure in a squashfs inside the
# initrd, with a tmpfs overlay as root. It is booted the same way as the
# bring-up initramfs, through m1n1 from the host (tools/m4run), with
# init=${toplevel}/init on the command line.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/netboot/netboot.nix")
    (modulesPath + "/profiles/minimal.nix")
  ];

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

  # The kernel's squashfs has zlib and xz, not zstd.
  netboot.squashfsCompression = "xz -Xdict-size 100%";

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

  # Keep the image small for the tethered upload (about 400 KiB/s): do not
  # embed the nixpkgs source (492 MB) for NIX_PATH and the flake registry.
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  # nixos-rebuild-ng is Python (148 MB); a system in RAM is rebuilt on the
  # host, not on itself.
  system.disableInstallerTools = true;
}
