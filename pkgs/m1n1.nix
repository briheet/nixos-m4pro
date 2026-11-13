# m1n1 for the J614s: nixpkgs' m1n1 package at the commit this machine was
# brought up with, plus the T6040 fixes in m1n1/patches.
#
#   release = true   RELEASE=1 CHAINLOADING=1, as nixpkgs and the Asahi
#                    installer build it: the stage 1 for the boot chain.
#   release = false  the debug build (chainloading too), as installed on
#                    macostest during bring-up
#                    (early UART at the T6040 address, proxy on debug USB).
{ lib, m1n1, gcc14Stdenv, fetchFromGitHub, release ? true }:

# Built like the m1n1 that first ran on this Mac (Debian trixie, gcc 14, no
# extra flags). nixpkgs' cc wrapper adds hardening flags by default
# (-fzero-call-used-regs, stack clash probes, ...), meant for Linux programs;
# with them and gcc 16, m1n1 stopped before drawing its logo on J614s.
# Firmware in nixpkgs (U-Boot, ATF) is built with hardening off too.
# m1n1's built-in logo rather than nixpkgs' custom-logo payload: the payload
# is appended after the image, and with it no Nix build of m1n1 came up as
# iBoot's boot object on J614s, while the same code chainloaded fine.
(m1n1.override { stdenv = gcc14Stdenv; customLogo = null; }).overrideAttrs (old: rec {
  hardeningDisable = [ "all" ];

  version = "2.0.0-unstable-2026-11-04-m4pro";

  src = fetchFromGitHub {
    owner = "AsahiLinux";
    repo = "m1n1";
    rev = "cf37927d6bf47c502136e7d2c9e61f946b0b8745";
    hash = "sha256-bgphbGh2xflPGsmM0EETEdIKmmHnjr/AEWH7OwML7J4=";
  };

  cargoDeps = m1n1.rustPlatform.fetchCargoVendor {
    pname = "m1n1";
    inherit version src;
    sourceRoot = "${src.name}/rust";
    hash = "sha256-7G9aTQEiQ8ocsY0gSoBg9A2cusfqR4a1nhFikpWMXAA=";
  };

  patches = lib.sort (a: b: a < b) (
    map (f: ../m1n1/patches + "/${f}") (builtins.attrNames (builtins.readDir ../m1n1/patches))
  );

  makeFlags =
    if release then
      old.makeFlags
    else
      [ "ARCH=" "CHAINLOADING=1" "EXTRA_CFLAGS=-DTARGET=0x6040" ];

  # The tests exercise the Python proxy client, not the binary.
  doCheck = false;
})
