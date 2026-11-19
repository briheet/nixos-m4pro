# GPU smoke test against a given Mesa (default: the system's pkgs.mesa,
# which on nixos-aurora is Aurora's Mesa with the aurora driver):
#
#   nix-build tools/gpu-smoke --arg mesa /nix/store/...-mesa-26.3.0
#   ./result/bin/gpu-smoke
#
# The wrapper points glvnd at that Mesa's EGL vendor file, so the system's
# own GL setup (hardware.graphics.package) is left alone.
{ pkgs ? import <nixpkgs> { }, mesa ? pkgs.mesa }:

pkgs.stdenv.mkDerivation {
  name = "gpu-smoke";
  src = ./.;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ pkgs.libglvnd ];
  buildPhase = ''
    $CC -O2 -Wall -o gpu-smoke smoke.c -lEGL -lGLESv2
  '';
  installPhase = ''
    install -Dm755 gpu-smoke $out/bin/.gpu-smoke-unwrapped
    makeWrapper $out/bin/.gpu-smoke-unwrapped $out/bin/gpu-smoke \
      --set __EGL_VENDOR_LIBRARY_FILENAMES ${mesa}/share/glvnd/egl_vendor.d/50_mesa.json \
      --set LIBGL_DRIVERS_PATH ${mesa}/lib/dri \
      --set GBM_BACKENDS_PATH ${mesa}/lib/gbm
  '';
}
