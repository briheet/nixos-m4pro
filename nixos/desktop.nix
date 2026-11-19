# The desktop on the installed system: Hyprland on the boot framebuffer.
#
# There is no GPU driver for the M4 yet, so Hyprland draws with Mesa's
# llvmpipe on the CPU into simpledrm (the framebuffer iBoot set up, which m1n1
# describes), at 3024x1964 and scale 2. Blur, shadows and animations start
# off because they cost the most in software, so keep them off in your
# Hyprland config (~/.config/hypr/hyprland.lua, from home-manager or your
# own; without one Hyprland writes its default).
#
# Log in on the screen (greetd/tuigreet); it starts Hyprland.
{ pkgs, ... }:

{
  config = {
    programs.hyprland.enable = true;
    # Mesa: llvmpipe for OpenGL ES and GBM on simpledrm.
    hardware.graphics.enable = true;

    # aquamarine (Hyprland's backend) finds no EGL device for simpledrm, which
    # has no render node, and retries on every commit. Its unmerged PR #406
    # falls back to the GBM platform, where llvmpipe works.
    nixpkgs.overlays = [
      (final: prev: {
        aquamarine = prev.aquamarine.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ../aquamarine/patches/0001-drm-fall-back-to-the-GBM-platform.patch
          ];
        });
      })
    ];
    # foot's default font, readable at scale 2 (override in ~/.config/foot).
    environment.etc."xdg/foot/foot.ini".text = ''
      [main]
      font=monospace:size=13
    '';

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --asterisks --cmd start-hyprland";
        user = "greeter";
      };
    };

    environment.systemPackages = with pkgs; [
      foot
      fuzzel
      firefox
      brightnessctl
      pavucontrol
    ];

    fonts.packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
      font-awesome
      dejavu_fonts
    ];
  };
}
