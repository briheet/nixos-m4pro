# The J614s (MacBook Pro 14", M4 Pro) kernel, built by Nix.
#
# Source: AsahiLinux/linux branch "asahi" at 6ba0637d1 (Linux 7.2.15), plus
# kernel/patches (the t604x device trees, the dockchannel console, the
# J614s PMGR list, MTP/keyboard nodes, and the PMGR bring-up changes).
# Config: kernel/m4pro-nixos.full.config, generated from allnoconfig plus
# kernel/m4pro-min.config and kernel/m4pro-nixos.config. Everything is
# built in; module support is enabled for NixOS's module tree.
{ lib, linuxManualConfig, fetchFromGitHub, ... }:

let
  patchDir = ../kernel/patches;
  patches = lib.sort lib.lessThan
    (lib.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir patchDir)));
in
linuxManualConfig {
  version = "7.2.15-m4pro-nixos";
  modDirVersion = "7.2.15-m4pro-nixos";
  src = fetchFromGitHub {
    owner = "AsahiLinux";
    repo = "linux";
    rev = "6ba0637d1ed9a2e3639dd3fc9eca6cd0483a6434";
    hash = "sha256-q5kIQl0w/yn4dqM5rPqq2pFenxgi53XjCBa3MUlyQKI=";
  };
  kernelPatches = map (name: { inherit name; patch = patchDir + "/${name}"; }) patches;
  configfile = ../kernel/m4pro-nixos.full.config;
  allowImportFromDerivation = true;
}
