#!/bin/sh
# Run a command in the kernel build environment, inside the
# nixos-m4pro-builder container (see docs/boot_linux/checklist.md, item 1).
# nixpkgs is the revision pinned in flake.lock.
#
#   docker exec nixos-m4pro-builder /work/tools/kernel-env.sh make -C /src/linux ...
set -e
NP=github:NixOS/nixpkgs/177d0540942fb205af6993b1d5fa0b57799e09f8
# nix develop on nixpkgs' kernel package gives the kernel's own build inputs
# (gcc, openssl, elfutils, bison, flex, bc, perl, ...) with include and
# library paths set, which nix shell does not do.
exec nix develop "$NP#linux" \
  --command sh -c 'PATH="$PATH:$(nix build --no-link --print-out-paths '"$NP"'#cpio)/bin"; exec "$@"' sh "$@"
