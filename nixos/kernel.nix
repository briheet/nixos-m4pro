# The J614s (MacBook Pro 14", M4 Pro) kernel, built by Nix.
#
# Source: the linux flake input (aurora-silicon/linux branch
# "integration/aurora", locked in flake.lock; `nix flake update linux`
# follows it), plus kernel/patches (only what aurora lacks).
# Config: kernel/m4pro-nixos.full.config, generated from arm64 defconfig,
# aurora's arch/arm64/configs/asahi.config, then kernel/m4pro-min.config
# and kernel/m4pro-nixos.config (ours win: storage, keyboard, console and
# Wi-Fi built in, so the initrd needs no modules). The Asahi-era patches
# and config are in kernel/asahi/.
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
