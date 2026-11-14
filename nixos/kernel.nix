# The J614s (MacBook Pro 14", M4 Pro) kernel, built by Nix.
#
# Source: the linux flake input (AsahiLinux/linux branch "asahi", locked in
# flake.lock; `nix flake update linux` follows upstream), plus
# kernel/patches (the t604x device trees, the dockchannel console, the
# J614s PMGR list, MTP/keyboard nodes, and the PMGR bring-up changes).
# Config: kernel/m4pro-nixos.full.config, generated from allnoconfig plus
# kernel/m4pro-min.config and kernel/m4pro-nixos.config. Everything is
# built in; module support is enabled for NixOS's module tree.
{ lib, linuxManualConfig, src, ... }:

let
  # The version from the source's own Makefile, so an update needs no edit.
  makefile = builtins.readFile (src + "/Makefile");
  field = name: lib.head (lib.concatMap
    (line: if builtins.match "${name} = ([0-9]+)" line == null then [ ] else builtins.match "${name} = ([0-9]+)" line)
    (lib.splitString "\n" makefile));
  kernelVersion = "${field "VERSION"}.${field "PATCHLEVEL"}.${field "SUBLEVEL"}";
  patchDir = ../kernel/patches;
  patches = lib.sort lib.lessThan
    (lib.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir patchDir)));
in
linuxManualConfig {
  version = "${kernelVersion}-m4pro-nixos";
  modDirVersion = "${kernelVersion}-m4pro-nixos";
  src = src.outPath or src;
  kernelPatches = map (name: { inherit name; patch = patchDir + "/${name}"; }) patches;
  configfile = ../kernel/m4pro-nixos.full.config;
  allowImportFromDerivation = true;
}
