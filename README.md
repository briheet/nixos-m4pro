# nixos-m4pro

NixOS on a 14-inch MacBook Pro with the M4 Pro (`Mac16,8`, board `J614s`, SoC `T6040`), which the Asahi installer does not support yet. Personal use: the patches here are written for this machine, not for upstream.

NixOS runs from the internal SSD and boots from power-on without the host: m1n1 → U-Boot → extlinux menu → NixOS ([docs/boot_linux/boot-chain.md](docs/boot_linux/boot-chain.md)). Working: all 12 CPUs (idling in WFI), the internal screen (boot framebuffer), keyboard, multitouch trackpad, SSD, Wi-Fi, Bluetooth, battery and charger, power button and lid, real-time clock, clean reboot, and a Hyprland desktop. [docs/required_for_daily_use/list.md](docs/required_for_daily_use/list.md) tracks every piece of hardware.

## What is in the repo

| Path | What |
|---|---|
| `flake.nix` | `nixosConfigurations.m4pro` (on the SSD), `m4pro-ram` (from RAM, the installer), packages `boot-files`, `m1n1`, `m1n1-dev`, `m1n1-stage1`, `u-boot` |
| `nixos/` | `common.nix` shared settings (kernel parameters, firmware, logins, NetworkManager, console font), `disk.nix` the installed system, `desktop.nix` Hyprland, `ram.nix` the installer, `kernel.nix` the kernel, `m1n1-boot.nix` writes stage 2 to the ESP |
| `kernel/patches/` | Patches on AsahiLinux/linux `6ba0637d`: J614s device trees (PMGR, NVMe, PMP, SMC, SPMI PMU, MTP, PCIe, Wi-Fi/Bluetooth), the dockchannel console, NVMe and PMP changes, and ports from aurora-silicon (WFI register save, MTP transport, brcmfmac BCM4388 C2) |
| `kernel/*.config` | Kernel configs; `m4pro-nixos.full.config` is the one NixOS builds, `m4pro-nixos.config` lists what was added and why |
| `m1n1/patches/` | m1n1 fixes for T6040 on m1n1 `cf37927d` (DAPF, CTRR, MCC, ANS quiesce, chainload) |
| `u-boot/patches/` | aurora-silicon U-Boot change for this boot chain (ANS handed over quiesced) |
| `pkgs/` | `m1n1.nix` (pinned m1n1 with the patches and the NixOS logo), `u-boot.nix`, `j614s-firmware.nix` (Apple firmware, pinned by hash), `m4pro-install.nix` (the installer) |
| `tools/` | Host side: `tether-boot.py`, `m4console`, `m4sh`, `m4reboot`, `uboot-boot`, `mac-firmware`, `m1n1-try`, `stage1-test.py` |
| `bin/`, `lib/` | `nixos-m4pro`, OCaml tools: ADT parser, PMGR device-tree generator, m1n1 proxy probes |
| `docs/` | Bring-up notes per subsystem, the boot chain, and the hardware list |

Everything is pinned: nixpkgs by `flake.lock`, the kernel, m1n1 and U-Boot sources by commit and hash, and the patches in the repo. Apple's firmware is the one input that cannot be in the repo: Nix knows it by hash, and `tools/mac-firmware` produces exactly those files from a Mac running macOS.

## What you need

- **The target:** the M4 Pro, with a second APFS volume (`macostest` here) with macOS installed on it and set to Reduced Security in Startup Security Utility. m1n1 goes on that volume as its custom boot object. Your normal macOS volume stays at Full Security and is not touched.
- **The host:** another Apple Silicon Mac running macOS, connected to the target's left USB-C port, with Docker (8 GB of memory is enough), Nix (for `just`), Python 3, OCaml/dune, and [macvdmtool](https://github.com/AsahiLinux/macvdmtool) built at `~/code/macvdmtool` (or set `MACVDMTOOL`). macvdmtool needs passwordless sudo for that one binary; nothing else does.
- Apps that grab USB devices (Chrome, ChatGPT) closed while debug USB connects.

Run everything below with `just`, from `nix develop` or `nix shell nixpkgs#just`.

## Install from scratch

1. **Host setup** (once):
   ```
   just builder        # Nix in an aarch64-linux container
   just setup          # m1n1 sources and proxy client, Python deps, OCaml tools
   tools/mac-firmware  # Apple firmware (trackpad, Wi-Fi, Bluetooth) into the builder's store
   just build          # kernel, device trees, RAM installer and SSD system into build/out
   ```
   `tools/mac-firmware` reads the host's own macOS (`/usr/share/firmware`, and `J614s_Multitouch.im4p` in the Preboot restore bundle): macOS carries the files of every model. The same macOS gives the same hashes as in `pkgs/j614s-firmware.nix`; another version gives a hash mismatch, and then the two `sha256` lines there change with it.
2. **Make room on the SSD**, in macOS on the M4 Pro. Back up first if you can. Check the container's physical store with `diskutil apfs list`; it is `disk0s2` on this Mac. Leave macOS headroom above what is in use:
   ```
   tmutil deletelocalsnapshots /
   diskutil apfs resizeContainer disk0s2 370g
   ```
3. **m1n1 stage 1 on `macostest`**, from 1TR recoveryOS (hold the power button, Options, then Utilities → Terminal):
   ```
   just m1n1-serve stage1     # on the host: builds m1n1 and serves the kmutil script on the USB link
   sh <(curl <address>:8000)  # in recoveryOS, with the address it prints
   ```
   Stage 1 chainloads `m1n1/boot.bin` from the ESP. Until the ESP exists it finds nothing to chainload and stays in m1n1's USB proxy, which the next step uses.
4. **Boot the installer** (the M4 Pro powered on into `macostest`):
   ```
   just restart
   just dev-boot ram   # a few minutes: the installer carries the whole system
   ```
5. **Install.** Each step asks for confirmation on the host and refuses on the target if it finds anything it did not expect (an existing NixOS partition or filesystem, a non-macOS layout, too little free space):
   ```
   just flash       # partition, format, install
   ```
   `partition` saves the GPT to `/root/gpt-before.bin` before changing it, and only adds partitions 4 and 5 in the free block between the macOS container and recoveryOS. The install writes stage 2 (m1n1 + device tree + U-Boot) to the ESP.
6. **Boot it:** power on, or `tools/m4reboot`. U-Boot boots the newest generation after 5 s (about 90 s to the login screen).
7. **Your password**, from the host (it prompts there; only the hash goes to the Mac):
   ```
   just set-password briheet
   ```
8. **On the Mac:** log in as `briheet` and pick Hyprland, then join Wi-Fi with `nmtui` (or `nmcli device wifi connect <SSID> --ask`).

## Using it

- **Logins:** `briheet` (wheel: `sudo`, video, input, networkmanager). Root is locked; it logs in by itself only on the debug-USB console (`ttyDC0`), which needs the cable to the host and is what `tools/m4sh` drives.
- **Desktop:** Hyprland, drawn on the CPU (no GPU driver for M4 yet) at scale 2. Super+Return terminal (foot), Super+D launcher (fuzzel), Super+B Firefox, Super+Q close, Super+1-5 workspaces, three-finger swipe between workspaces, Super+Shift+E log out. The first login copies `/etc/hypr/hyprland.conf` to `~/.config/hypr/`; blur, shadows and animations start off.
- **Boot menu:** U-Boot's extlinux menu lists the generations. The internal keyboard does not work in U-Boot yet; another entry can be picked over the debug-USB console (`tools/uboot-boot`).
- **Reboots:** `systemctl reboot` restarts through the SMC. From the host, `tools/m4reboot` does the same when Linux answers on the console and a hard reset otherwise.
- **The Recovery / Startup Disk screen:** iBoot counts failed boots in the PMU and stops booting the volume after a run of hard resets. Linux clears the count on every boot, and so does the m1n1 proxy client; if the screen shows anyway, pick Startup Disk → `macostest`.

## Updating

Change the flake, then:

```
just build
just stage2-proxy   # U-Boot has no USB proxy: put the debug m1n1 back as stage 2
just dev-boot ram
just flash-system   # adds a generation and writes the U-Boot stage 2 back
tools/m4reboot
```

`sshd` is on (keys only), so once the Mac is on Wi-Fi and your key is in `~briheet/.ssh/authorized_keys`, updates can go over the network with `nixos-rebuild --target-host` instead.

## Testing without installing

- `tools/uboot-boot -- ARG -ARG ...` reboots, stops U-Boot over debug USB, and boots the installed generation with words added to or (`-ARG`) removed from its command line, for example `tools/uboot-boot -- dockchannel_hid.dyndbg=+p` for a driver's debug messages.
- `M1N1DEVICE=/dev/cu.kis-100000-ch-0 .venv-m1n1/bin/python tools/tether-boot.py Image.gz dtb initrd -b "args"` boots any kernel over debug USB from the m1n1 proxy, with the console captured from the first line.
- `tools/m1n1-try image.bin` runs an m1n1 image (or a whole stage 2) the way stage 1 chainloads it.

## Recipes

| Recipe | Does |
|---|---|
| `builder`, `setup` | host setup |
| `build` | `.#boot-files` into `build/out` |
| `m1n1 [stage1\|dev]` | m1n1 into `build/out` |
| `restart` | restart into m1n1 and wait for its USB device |
| `dev-boot [ram\|disk]` | boot the installer or the SSD's system: m1n1's stock `linux.py` over m1n1's USB device (about 9.5 MB/s), then the console over debug USB |
| `connect`, `boot-ram`, `boot-disk` | fallback: everything over debug USB (about 0.5 MB/s) |
| `sh "cmd" [timeout]` | run a command on the target's root shell, with its exit status |
| `flash-partition`, `flash-format`, `flash-system`, `flash` | install to the SSD |
| `set-password user` | set a user's password from the host, sending only its hash |
| `m1n1-serve [stage1\|dev]` | install m1n1 from recoveryOS |
| `stage2-proxy` | from the U-Boot boot chain back to the USB proxy (debug m1n1 as stage 2) |
| `stage2-serve` | serve the debug m1n1 to copy onto the ESP from recoveryOS, if stage 2 fails |

Every boot is recorded under `build/runs/<time>/` (console log with timestamps, commands run, host log), with an index in `build/runs/index.md`.

## Known gaps

No GPU acceleration, no backlight control, no sound, no suspend or CPU frequency scaling, no trackpad haptics, no USB-C data, no keyboard in U-Boot's menu, and the m1n1 logo of stage 1 is still Asahi's until stage 1 is reinstalled. The order of work is in [docs/required_for_daily_use/list.md](docs/required_for_daily_use/list.md).
