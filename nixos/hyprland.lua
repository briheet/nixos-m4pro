-- Hyprland config for the M4 Pro (nixos/hyprland.lua, installed as
-- /etc/hypr/hyprland.lua and copied to ~/.config/hypr/ at the first login).
-- Yours to edit after that. Hyprland 0.57 reads Lua; the wiki is at
-- https://wiki.hypr.land/configuring/
--
-- Rendering is on the CPU (Mesa llvmpipe, no GPU driver for the M4 yet), so
-- blur, shadows and animations start off. Turn them on below if they are
-- smooth enough.

---- Monitor: the 3024x1890 panel at scale 2 ----
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 2,
})

---- Programs ----
local terminal = "foot"
local menu     = "fuzzel"
local browser  = "firefox"

hl.on("hyprland.start", function ()
    hl.exec_cmd("waybar")
end)

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("QT_QPA_PLATFORM", "wayland")

---- Look ----
hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 2,
        col = {
            active_border   = "rgba(7ebae4ff)",
            inactive_border = "rgba(595959aa)",
        },
        resize_on_border = true,
        layout = "dwindle",
    },

    decoration = {
        rounding = 6,
        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = { enabled = false },

    dwindle = { preserve_split = true },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        vfr = true,
    },
})

---- Input: the MacBook keyboard and trackpad ----
hl.config({
    input = {
        kb_layout    = "us",
        follow_mouse = 1,
        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            clickfinger_behavior = true,
            scroll_factor        = 0.5,
        },
    },
})

-- Three fingers left/right: next/previous workspace.
hl.gesture({
    fingers   = 3,
    direction = "horizontal",
    action    = "workspace",
})

---- Keys: Super is the Command key ----
local mod = "SUPER"

hl.bind(mod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mod .. " + D", hl.dsp.exec_cmd(menu))
hl.bind(mod .. " + B", hl.dsp.exec_cmd(browser))
hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + J", hl.dsp.layout("togglesplit"))
hl.bind(mod .. " + SHIFT + E", hl.dsp.exec_cmd("hyprctl dispatch 'hl.dsp.exit()'"))

hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "down" }))

for i = 1, 10 do
    local key = i % 10
    hl.bind(mod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

---- Windows ----
hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})
