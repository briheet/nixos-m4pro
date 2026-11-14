# m1n1 for the J614s: nixpkgs' m1n1 package built from the m1n1 flake input
# (AsahiLinux/m1n1, locked in flake.lock), plus the T6040 fixes in
# m1n1/patches. `nix flake update m1n1` follows upstream.
#
#   release = true   RELEASE=1 CHAINLOADING=1, as nixpkgs and the Asahi
#                    installer build it: the stage 1 for the boot chain.
#   release = false  the debug build (chainloading too), as installed on
#                    macostest during bring-up
#                    (early UART at the T6040 address, proxy on debug USB).
#   showNotch = true the OS gets the whole panel, notch area included
#                    (m1n1/patches/0009); otherwise the 16:10 part below it.
{ lib, m1n1, gcc14Stdenv, rustPlatform, imagemagick, nixos-icons, src, release ? true, showNotch ? false }:

# Built like the m1n1 that first ran on this Mac (Debian trixie, gcc 14, no
# extra flags). nixpkgs' cc wrapper adds hardening flags by default
# (-fzero-call-used-regs, stack clash probes, ...), meant for Linux programs;
# with them and gcc 16, m1n1 stopped before drawing its logo on J614s.
# Firmware in nixpkgs (U-Boot, ATF) is built with hardening off too.
# m1n1's built-in logo rather than nixpkgs' custom-logo payload: the payload
# is appended after the image, and with it no Nix build of m1n1 came up as
# iBoot's boot object on J614s, while the same code chainloaded fine.
let
  patchDir = ../m1n1/patches;
  patchFiles = lib.sort (a: b: a < b) (builtins.attrNames (builtins.readDir patchDir));
  # What m1n1 reports as its version (chosen/asahi,m1n1-stage1-version and
  # -stage2-version in Linux's device tree): the upstream commit and a hash
  # of the patches on it. Without it a build from a tarball says "unknown".
  versionTag =
    "${src.shortRev or "dirty"}-m4pro-"
    + builtins.substring 0 8 (
      builtins.hashString "sha256" (lib.concatMapStrings (f: builtins.readFile (patchDir + "/${f}")) patchFiles)
    );
in
(m1n1.override { stdenv = gcc14Stdenv; customLogo = null; }).overrideAttrs (old: {
  hardeningDisable = [ "all" ];
  env = (old.env or { }) // {
    M1N1_VERSION_TAG = versionTag;
  };
  passthru = (old.passthru or { }) // {
    inherit versionTag;
  };

  version = "2.0.0-unstable-${src.lastModifiedDate or "0"}-${src.shortRev or "dirty"}-m4pro";
  src = src.outPath or src;

  # From m1n1's own Cargo.lock, so an update needs no vendor hash; only its
  # git dependency is pinned here, by the commit Cargo.lock names.
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/rust/Cargo.lock";
    outputHashes = {
      "fatfs-0.4.0" = "sha256-tcchdtuIIN8fkLy/qf9hazkPGT2kdYuPUtC/C1bRfIQ=";
    };
  };

  patches = map (f: patchDir + "/${f}") patchFiles;

  makeFlags =
    if release then
      old.makeFlags ++ lib.optional showNotch "EXTRA_CFLAGS=-DM1N1_SHOW_NOTCH"
    else
      [ "ARCH=" "CHAINLOADING=1" "EXTRA_CFLAGS=-DTARGET=0x6040" ];

  # The NixOS snowflake instead of the Asahi logo: the logos m1n1 compiles
  # in (raw RGBA, 48/128/256 px squares on black), regenerated from
  # nixos-icons. Same sizes, so the image size does not change.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ imagemagick ];
  postPatch = (old.postPatch or "") + ''
    for s in 48 128 256; do
      magick ${nixos-icons}/share/icons/hicolor/256x256/apps/nix-snowflake.png \
        -background black -flatten -resize ''${s}x''${s} -gravity center -extent ''${s}x''${s} \
        -depth 8 rgba:data/bootlogo_$s.bin
      test "$(stat -c %s data/bootlogo_$s.bin)" -eq $((s * s * 4))
    done
  '';

  # The tests exercise the Python proxy client, not the binary.
  doCheck = false;
})
