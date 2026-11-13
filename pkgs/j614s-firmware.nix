# Firmware for the J614s that comes from Apple and cannot be in this repo:
# Nix knows it only by hash. Add it to the store once (in the builder) with
#
#   nix-store --add-fixed sha256 build/firmware/apple/tpmtfw-j614s.bin
#
# tpmtfw-j614s.bin is the trackpad (multi-touch) firmware, converted with
# Asahi's asahi_firmware.multitouch from J614s_Multitouch.im4p in a macOS
# restore bundle (docs/boot_linux/keyboard.md).
{ requireFile, runCommand }:

let
  tpmtfw = requireFile {
    name = "tpmtfw-j614s.bin";
    sha256 = "a1f4131d0cb7caf6fa15b19f47725458a6d7b0e3a34f15169339d5541663d9e2";
    message = ''
      tpmtfw-j614s.bin (the J614s trackpad firmware) is not in the Nix store.
      Convert it from macOS (docs/boot_linux/keyboard.md), then run
        nix-store --add-fixed sha256 build/firmware/apple/tpmtfw-j614s.bin
    '';
  };
in
runCommand "j614s-firmware" { } ''
  install -D -m 444 ${tpmtfw} $out/lib/firmware/apple/tpmtfw-j614s.bin
''
