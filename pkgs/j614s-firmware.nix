# Firmware for the J614s that comes from Apple and cannot be in this repo:
# Nix knows it only by hash. tools/mac-firmware, run on a Mac with macOS,
# converts it and adds it to the builder's store.
#
# tpmtfw-j614s.bin is the trackpad (multi-touch) firmware, converted with
# Asahi's asahi_firmware.multitouch from J614s_Multitouch.im4p in a macOS
# restore bundle (docs/boot_linux/keyboard.md).
#
# brcm-mriya.tar is the BCM4388 C2 Wi-Fi and Bluetooth firmware for this Mac's
# module ("mriya" in the ADT), converted by tools/mac-firmware from a macOS
# /usr/share/firmware; the tool also adds it to the store.
{ requireFile, runCommand }:

let
  tpmtfw = requireFile {
    name = "tpmtfw-j614s.bin";
    sha256 = "a1f4131d0cb7caf6fa15b19f47725458a6d7b0e3a34f15169339d5541663d9e2";
    message = ''
      tpmtfw-j614s.bin (the J614s trackpad firmware) is not in the Nix store.
      On a Mac running macOS, run tools/mac-firmware.
    '';
  };
  brcm = requireFile {
    name = "brcm-mriya.tar";
    sha256 = "de724973534c07fb31e71969b6e959978763df6ccdfe943c6a8d5e23b876198f";
    message = ''
      brcm-mriya.tar (the J614s Wi-Fi and Bluetooth firmware) is not in the
      Nix store. On a Mac running macOS, run tools/mac-firmware.
    '';
  };
in
# Fixed-output: the store path depends only on this hash, not on the nixpkgs
# that builds it, so every configuration (this repo's, or a personal one on
# another nixpkgs) finds the same path, and a machine that has it needs
# neither source file.
runCommand "j614s-firmware" {
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = "sha256-E+y3HSffw9IO6+pir2Zol0sBbhOOhgDUy1SqCn3iCQ4=";
} ''
  install -D -m 444 ${tpmtfw} $out/lib/firmware/apple/tpmtfw-j614s.bin
  tar -C $out -xf ${brcm}
''
