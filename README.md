# nixos-m4pro

NixOS on a 14-inch MacBook Pro with the M4 Pro (`Mac16,8`, board `J614s`, SoC `T6040`), which the Asahi installer does not support yet. Personal use: the patches here are written for this machine, not for upstream.

NixOS runs from the internal SSD, with the screen, the internal keyboard and the SSD working, and boots from power-on without the host: m1n1 → U-Boot → extlinux menu → NixOS ([docs/boot_linux/boot-chain.md](docs/boot_linux/boot-chain.md)). [docs/required_for_daily_use/list.md](docs/required_for_daily_use/list.md) tracks every piece of hardware.

## What is in the repo

| Path | What |
|---|---|
| `flake.nix` | `nixosConfigurations.m4pro` (on the SSD), `m4pro-ram` (from RAM, the installer), packages `boot-files`, `m1n1`, `m1n1-dev`, `m1n1-stage1`, `u-boot` |
| `nixos/` | `common.nix` shared settings, `disk.nix` the installed system, `ram.nix` the installer, `kernel.nix` the kernel, `m1n1-boot.nix` writes stage 2 to the ESP |
| `kernel/patches/` | Patches on AsahiLinux/linux `6ba0637d`: device trees for J614s, the dockchannel console, keyboard, NVMe, and one mainline NVMe driver change |
| `kernel/*.config` | Kernel configs; `m4pro-nixos.full.config` is the one NixOS builds |
| `m1n1/patches/` | m1n1 fixes for T6040 on m1n1 `cf37927d` (DAPF, CTRR, MCC, ANS quiesce, chainload) |
| `u-boot/patches/` | aurora-silicon U-Boot change for this boot chain (ANS handed over quiesced) |
| `pkgs/` | `m1n1.nix` (nixpkgs' m1n1 at the pinned commit with the patches), `u-boot.nix`, `m4pro-install.nix` (the installer) |
| `tools/` | Host side of the debug link: `tether-boot.py` (boot through m1n1), `m4boot`, `m4sh` |
| `bin/`, `lib/` | `nixos-m4pro`, OCaml tools: ADT parser, PMGR device-tree generator, m1n1 proxy probes |
| `docs/` | Bring-up notes, checklists, and the boot-chain plan |

Everything is pinned: nixpkgs by `flake.lock`, the kernel and m1n1 sources by commit and hash, and the patches in the repo. No step reaches for an unpinned source.

## What you need

- **The target:** the M4 Pro, with a second APFS volume (`macostest` here) set to Reduced Security, and m1n1 installed on it as the custom boot object (see "m1n1 on the target" below). Your normal macOS volume stays at Full Security and is not touched.
- **The host:** another Apple Silicon Mac, connected to the target's USB-C port, with Docker, Nix (for `just`), Python 3, OCaml/dune, and [macvdmtool](https://github.com/AsahiLinux/macvdmtool) built at `~/code/macvdmtool` (or set `MACVDMTOOL`). macvdmtool needs passwordless sudo for that one binary; nothing else does.
- Apps that grab USB devices (Chrome, ChatGPT) closed while debug USB connects.

Run everything below with `just`, from `nix develop` or `nix shell nixpkgs#just`.

## Install from scratch

1. **Host setup** (once):
   ```
   just builder     # Nix in an aarch64-linux container
   just setup       # m1n1 sources and proxy client, Python deps, OCaml tools
   just build       # kernel, device tree, RAM installer and SSD system into build/out
   ```
2. **Make room on the SSD**, in macOS on the M4 Pro. Back up first if you can. Check the container's physical store with `diskutil apfs list`; it is `disk0s2` on this Mac. Leave macOS headroom above what is in use:
   ```
   tmutil deletelocalsnapshots /
   diskutil apfs resizeContainer disk0s2 370g
   ```
3. **Boot the installer** (the M4 Pro powered on into m1n1 on `macostest`):
   ```
   just connect
   just dev-boot ram   # about 40 s
   ```
4. **Install.** Each step asks for confirmation on the host and refuses on the target if it finds anything it did not expect (an existing NixOS partition or filesystem, a non-macOS layout, too little free space):
   ```
   just flash       # partition, format, install
   ```
   `partition` saves the GPT to `/root/gpt-before.bin` before changing it, and only adds partitions 4 and 5 in the free block between the macOS container and recoveryOS.
5. **Boot it:** power on, or `sudo macvdmtool reboot`. Stage 1 on `macostest` loads the stage 2 the install wrote to the ESP, and U-Boot boots the newest generation after 5 s (about 90 s to login). Over debug USB the console is `ttyDC0`.

## Updating

Change the flake, then `just build`, `just stage2-proxy` (U-Boot has no USB proxy; this puts the debug m1n1 back as stage 2), `just restart`, `just dev-boot ram`, `just flash-system` (adds a generation and writes the U-Boot stage 2 back), and reboot. Once the Mac has a network this becomes an ordinary `nixos-rebuild`.

## m1n1 on the target

m1n1 is installed as the boot object of `macostest` from 1TR recoveryOS (hold power, Options, then Utilities → Terminal):

```
just m1n1-serve stage1     # on the host: builds m1n1 and serves the kmutil script on the USB link
sh <(curl <address>:8000)  # in recoveryOS, with the address it prints
```

Installed today: `stage1` (release m1n1 that chainloads stage 2 from the ESP). `dev` is the bring-up build with the USB proxy.

## Recipes

| Recipe | Does |
|---|---|
| `builder`, `setup` | host setup |
| `build` | `.#boot-files` into `build/out` |
| `m1n1 [release\|dev]` | m1n1 into `build/out` |
| `restart` | restart into m1n1 and wait for its USB device |
| `dev-boot [ram\|disk]` | boot the installer or the SSD's system: m1n1's stock `linux.py` over m1n1's USB device (about 9.5 MB/s), then the console over debug USB |
| `connect`, `boot-ram`, `boot-disk` | fallback: everything over debug USB (about 0.5 MB/s) |
| `sh "cmd" [timeout]` | run a command on the target's root shell, with its exit status |
| `flash-partition`, `flash-format`, `flash-system`, `flash` | install to the SSD |
| `m1n1-serve [stage1\|dev]` | install m1n1 from recoveryOS |
| `stage2-proxy` | from the U-Boot boot chain back to the USB proxy (debug m1n1 as stage 2) |
| `stage2-serve` | serve the debug m1n1 to copy onto the ESP from recoveryOS, if stage 2 fails |

Every boot is recorded under `build/runs/<time>/` (console log with timestamps, commands run, host log), with an index in `build/runs/index.md`.

## Known gaps

No network, no suspend or CPU frequency scaling, no trackpad haptics. The trackpad needs its firmware added to the Nix store once (docs/boot_linux/keyboard.md). The internal keyboard does not work in U-Boot's menu yet. The order of work is in [docs/required_for_daily_use/list.md](docs/required_for_daily_use/list.md).
