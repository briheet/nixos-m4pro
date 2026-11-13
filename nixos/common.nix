# This repo's own systems on the J614s (the installer from RAM, ram.nix, and
# the reference install, disk.nix): the hardware module plus a small policy.
# A personal configuration elsewhere imports nixosModules.default (and
# .desktop) instead and brings its own policy.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
    ./j614s.nix
  ];

  system.stateVersion = "26.05";
  networking.hostName = "m4pro";

  # The screen asks for a password; root logs in only on the debug console
  # (nixos/j614s.nix).
  users.users.briheet = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "input" "networkmanager" ];
    # No password in this (public) repo: `just set-password briheet` sets
    # one from the host, sending only its hash.
  };

  # Updates over the network: key-only SSH. Add a public key to
  # ~/.ssh/authorized_keys on the Mac.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # The firmware files (pkgs/j614s-firmware.nix) are Apple's; a personal
  # configuration with allowUnfree = true needs nothing.
  nixpkgs.config.allowUnfreePredicate =
    pkg: builtins.elem (lib.getName pkg) [ "tpmtfw-j614s.bin" "brcm-mriya.tar" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # The installer travels over USB, so leave out the nixpkgs source (217 MB,
  # for NIX_PATH and the flake registry) and nixos-rebuild-ng (147 MB).
  # `just update` builds and switches without them.
  nixpkgs.flake.setNixPath = false;
  nixpkgs.flake.setFlakeRegistry = false;
  system.disableInstallerTools = true;
}
