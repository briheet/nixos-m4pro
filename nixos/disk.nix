# This repo's reference install on the J614s's SSD: the hardware and boot
# chain (nixosModules.default), this repo's policy, and the Hyprland desktop.
{ ... }:

{
  imports = [
    ./j614s-ssd.nix
    ./common.nix
    ./desktop.nix
  ];
}
