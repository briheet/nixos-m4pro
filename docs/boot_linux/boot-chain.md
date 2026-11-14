# Booting from the SSD without the host

Since 2026-11-13 the Mac powers on into NixOS by itself: no host, no debug USB. The Apple startup picker chooses between macOS and NixOS, and U-Boot's extlinux menu chooses between NixOS generations. This page records how the chain is built and what it took on the M4 Pro.

## The chain

```
power on
  └─ iBoot (Apple)                       picks the volume: Startup Disk, or hold power for the picker
      └─ m1n1 stage 1 on macostest        kmutil custom boot object; chainload=<ESP PARTUUID>;m1n1/boot.bin
          └─ m1n1 stage 2 on the ESP      nvme0n1p4:/m1n1/boot.bin = release m1n1 + t6040-j614s.dtb + U-Boot
              └─ U-Boot                    aurora-silicon fork: T6040 NVMe, dockchannel serial
                  └─ extlinux menu         /boot/extlinux/extlinux.conf, one entry per generation (5 s)
                      └─ Linux + initrd    root on nvme0n1p5
```

Only stage 1 needs a trip to recoveryOS; each switch puts the matching one on the ESP with `m1n1/stage1-install.sh` for that trip, and `m1n1-status` shows which stage 1 booted (README, Boot chain updates). Stage 2, U-Boot and the menu sit on the ESP; `nixos/m1n1-boot.nix` writes stage 2 with the boot loader, so `nixos-rebuild` (or `just flash-system`) updates them with each generation. From power-on to the login prompt takes about 90 s.

## Status

| # | Step | Status |
|---|---|---|
| 1 | **m1n1 stage 1**, release build with chainloading (`just m1n1`), installed on `macostest` from 1TR with `kmutil` (`just m1n1-serve`) | Done: padded to 0x3f4000, chainloads stage 2 on every power-on |
| 2 | **Chainloading on M4** | Done: m1n1 patch 0008 moves iBoot's boot blobs; Linux keeps the SSD afterwards (pmp.md) |
| 3 | **Stage 2 in the NixOS system**: `boot.m1n1.stage2` in nixos/j614s-ssd.nix, installed by nixos/m1n1-boot.nix | Done |
| 4 | **U-Boot for the M4 Pro**: `pkgs/u-boot.nix` (aurora-silicon `aurora-wip`, `apple_m1_defconfig`) with u-boot/patches | Done for NVMe and serial; the internal keyboard does not work in U-Boot yet (MTP helper: "DART bypass unavailable") |
| 5 | **Boot menu**: extlinux (`generic-extlinux-compatible`), without the generation's device tree so Linux gets the one m1n1 filled in | Done; systemd-boot through U-Boot's EFI is not needed |
| 6 | **Name in the startup picker**: `diskutil rename macostest NixOS` in macOS | Optional |

## Findings: U-Boot (2026-11-13)

Tested from the host before anything was written to the SSD: `tools/tether-boot.py -r` runs a stage 2 image exactly as stage 1 chainloads it, and U-Boot's prompt is reachable over the dockchannel (input must stay under 64 bytes a line; U-Boot's watchdog resets the Mac 60 s after it stops servicing it).

- **ANS arrives quiesced.** Our m1n1 stages hand ANS over quiesced (m1n1 patch 0005), with the controller disabled but programmed. aurora's U-Boot took that for a live session to adopt and waited forever for CSTS.RDY. u-boot/patches/0001 runs the INIT handshake whenever the controller is disabled and quiesces ANS again at hand-off, which Linux (kernel patch 0021) wakes as it does after m1n1.
- **The device tree needs names U-Boot looks up**: `reg-names = "data"` on the dockchannel UART and the NVMMU window as a third NVMe reg (`nvme`, `ans`, `nvmmu`), plus an empty `/reserved-memory` node for its fix-ups (kernel patches 0022, 0023).
- **M4 cores lose their registers on WFI and WFIT.** On M1–M3 m1n1 sets `CYC_OVRD` so WFI keeps state; on M4 iBoot locks it. m1n1's kboot therefore appends `idle=nop arm64.nowfxt` to the kernel command line, but U-Boot replaces the command line with the extlinux `APPEND`, and every secondary CPU then crashed on its first idle (pc 0, all registers zero). `arm64.nowfxt` is now in `boot.kernelParams` (nixos/j614s.nix); instead of `idle=nop`, kernel patch 0024 saves the registers around the idle WFI. See Yureka Lilian's "The forgetful CPU" and the upstream erratum thread "arm64: errata: Handle Apple WFI State Loss".
- **U-Boot points `/chosen/stdout-path` at the framebuffer** when it has a keyboard driver and `stdout` includes vidconsole, which moves Linux's `earlycon` off the dockchannel. Set `stdout serial` at the prompt to see early kernel output on the host.

## Tethered work with U-Boot as stage 2

U-Boot does not run m1n1's USB proxy, so `just restart` and `just dev-boot` need the debug m1n1 back:

```
just stage2-proxy   # reboot, stop U-Boot over debug USB, copy m1n1/dev.bin over m1n1/boot.bin
just restart        # now reaches the proxy as before
```

The next `just flash-system` (or `nixos-rebuild boot`) writes the U-Boot stage 2 back. If U-Boot itself ever fails to start, `just stage2-serve` puts the debug m1n1 on the ESP from 1TR recoveryOS.

## Findings (2026-11-13)

Tested without recovery trips with `tools/m1n1-try`, which runs an m1n1 image the way stage 1 starts stage 2 (proxyclient `chainload.py -r`: same base, entry 0x800, RVBAR untouched) and shows the new m1n1's log on the debug link.

- **Stage 1 must end its config lines with four NUL bytes**, as asahi-installer `src/m1n1.py` writes them. Without them m1n1 scans past the image for payloads when iBoot loads it; on J614s every such image stopped before drawing its logo, and iBoot fell back to the recovery/startup-disk screen. `m1n1-stage1` in the flake does this now.
- m1n1 is built with gcc 14 and `hardeningDisable = [ "all" ]` (`pkgs/m1n1.nix`), like other firmware in nixpkgs; the code then matches the Docker build except for nixpkgs' appended logo.
- **Chainloading works on T6040.** `m1n1-stage1` (release) initialises ANS through ADT reg 9, finds the ESP by PARTUUID, loads `m1n1/boot.bin` (5373968 bytes) and stage 2 comes up in its proxy.
- **Linux's NVMe fails after any ANS sleep.** m1n1 puts ANS to sleep and resets it after reading the ESP; Linux then cold-boots it and ANS crashes with an SError (FAR 0x41f008000 in ANS's address space, not in the ADT). The same happens with Linux alone: unbinding and rebinding `nvme-apple` makes ANS crash while entering IOP sleep (`NVMe shutdown start ... saveCtx`, AP quiesce acked, then SError at 0x41f020000). Direct boots only work because iBoot leaves ANS running and Linux wakes it instead of cold-booting it. Ruled out: the PMGR reset sequence, `apcie_sys_st0` state, NVMe controller shutdown, and the NVMe/NVMMU/IOQ registers m1n1 leaves set.
- Solved: see pmp.md. PMP is started by Linux, ANS power is reported to it, and both Linux and m1n1 stop M4-class ANS by quiescing it with its CPU running; m1n1 stage 1 then hands over to Linux with the SSD working.

## Stage 1 on T6040 (2026-11-13)

Recorded from iBoot's own serial output, which debug USB carries when the port is switched during boot (`build/catch-boot.sh` style capture), and tested from the host with `tools/stage1-test.py` (calls the installed m1n1's chainload in iBoot's memory layout) and `tools/m1n1-try`:

- **iBoot panics (3bdace14b1a9a68:2081) on a boot object that is not a whole number of 16 KiB pages** (mBoot-20457.41.3). m1n1 alone is; the appended `chainload=` lines are not, so every stage 1 failed while the plain m1n1 (0x4d0000, 0x3f0000) booted. The later attempts show :1065, iBoot's failed-boot path. Stage 1 is zero-padded after its terminator to 0x3f4000. (m1n1 patch 0007, the hypervisor's 1 MiB of VNCR pages moved out of .bss, came from a wrong size-limit theory but stays: it keeps the image 1 MiB smaller.)
- **iBoot places RTBuddySeg, SEPFW, SEPPatches, uStuff, preoslog and BootArgs directly after the boot object**, where stage 1 copies stage 2. m1n1's built-in chainload moved only SEPFW (upstream fixed chainload.py in 00b78fa6, not chainload.c); m1n1 patch 0008 moves them all.
- Stage 1 hands ANS over quiesced (patch 0005), as M4 needs.
- Not the cause, though tried: nixpkgs' logo payload (dropped anyway), the Nix toolchain, the raw vs Mach-O format (iBoot enters a Mach-O without `__TEXT_BOOT_EXEC` like a raw object; aurora-silicon's padding is for Linux's execute window).

## Choosing an OS

- **macOS or NixOS:** the Apple startup picker (hold the power button at boot) lists every volume with a boot object, so both appear. Startup Disk in macOS, or in the picker, sets the default.
- **Which NixOS generation:** U-Boot's extlinux menu, the same `extlinux.conf` as on other NixOS ARM boards. It boots the default after 5 s; until U-Boot reads the internal keyboard, another entry can only be picked over the debug-USB console. Generations built before 2026-11-13 lack `idle=nop arm64.nowfxt` and crash when booted through U-Boot.
