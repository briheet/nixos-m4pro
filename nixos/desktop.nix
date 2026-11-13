# The desktop on the installed system: Hyprland on the boot framebuffer.
#
# There is no GPU driver for the M4 yet, so Hyprland draws with Mesa's
# llvmpipe on the CPU into simpledrm (the framebuffer iBoot set up, which m1n1
# describes), at 3024x1964 and scale 2. Blur, shadows and animations start
# off because they cost the most in software; turn them on in
# ~/.config/hypr/hyprland.conf if they are smooth enough.
#
# Log in on the screen (greetd/tuigreet) and pick Hyprland. The first login
# copies /etc/hypr/hyprland.conf to ~/.config/hypr/, which is then yours.
{ config, lib, pkgs, ... }:

let
  hyprConf = pkgs.writeText "hyprland.conf" ''
    # Default Hyprland config for the M4 Pro (nixos/desktop.nix). Yours to edit.

    monitor = , preferred, auto, 2

    env = XCURSOR_SIZE,24
    env = QT_QPA_PLATFORM,wayland
    env = MOZ_ENABLE_WAYLAND,1

    exec-once = waybar

    input {
      kb_layout = us
      follow_mouse = 1
      touchpad {
        natural_scroll = true
        tap-to-click = true
        clickfinger_behavior = true
        scroll_factor = 0.5
      }
    }

    # Three fingers left/right: next/previous workspace.
    gesture = 3, horizontal, workspace

    general {
      gaps_in = 4
      gaps_out = 8
      border_size = 2
      layout = dwindle
    }

    # Software rendering: the expensive effects start off.
    decoration {
      rounding = 6
      blur {
        enabled = false
      }
      shadow {
        enabled = false
      }
    }

    animations {
      enabled = false
    }

    misc {
      vfr = true
      disable_hyprland_logo = true
      disable_splash_rendering = true
    }

    $mod = SUPER

    bind = $mod, Return, exec, foot
    bind = $mod, D, exec, fuzzel
    bind = $mod, B, exec, firefox
    bind = $mod, Q, killactive
    bind = $mod SHIFT, E, exit
    bind = $mod, F, fullscreen
    bind = $mod, V, togglefloating
    bind = $mod, left, movefocus, l
    bind = $mod, right, movefocus, r
    bind = $mod, up, movefocus, u
    bind = $mod, down, movefocus, d
    bind = $mod, 1, workspace, 1
    bind = $mod, 2, workspace, 2
    bind = $mod, 3, workspace, 3
    bind = $mod, 4, workspace, 4
    bind = $mod, 5, workspace, 5
    bind = $mod SHIFT, 1, movetoworkspace, 1
    bind = $mod SHIFT, 2, movetoworkspace, 2
    bind = $mod SHIFT, 3, movetoworkspace, 3
    bind = $mod SHIFT, 4, movetoworkspace, 4
    bind = $mod SHIFT, 5, movetoworkspace, 5
    bindm = $mod, mouse:272, movewindow
    bindm = $mod, mouse:273, resizewindow
  '';

  # Seed the user's config once, then start Hyprland through its launcher.
  startHyprland = pkgs.writeShellScript "start-hyprland-m4pro" ''
    if [ ! -e "$HOME/.config/hypr/hyprland.conf" ]; then
      mkdir -p "$HOME/.config/hypr"
      install -m 644 /etc/hypr/hyprland.conf "$HOME/.config/hypr/hyprland.conf"
    fi
    exec start-hyprland
  '';
in
{
  programs.hyprland.enable = true;
  # Mesa: llvmpipe for OpenGL ES and GBM on simpledrm.
  hardware.graphics.enable = true;

  environment.etc."hypr/hyprland.conf".source = hyprConf;
  # foot's default font, readable at scale 2 (override in ~/.config/foot).
  environment.etc."xdg/foot/foot.ini".text = ''
    [main]
    font=monospace:size=13
  '';

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --asterisks --cmd ${startHyprland}";
      user = "greeter";
    };
  };

  environment.systemPackages = with pkgs; [
    foot
    fuzzel
    waybar
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

  # Updates over the network once Wi-Fi is up: key-only SSH. Add your public
  # key to ~/.ssh/authorized_keys on the Mac.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
