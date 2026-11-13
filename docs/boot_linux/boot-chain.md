# Booting from the SSD without the host

Today NixOS is installed on the SSD, but the kernel still comes from the host: m1n1 on `macostest` runs its USB proxy, and `just boot-disk` sends the kernel, device tree and initrd, which then mount the root filesystem from `nvme0n1p5`. This page is the plan for the standard chain Asahi Linux and nixos-apple-silicon use. With it the Mac powers on into NixOS by itself, the Apple startup picker chooses between macOS and NixOS, and a boot menu chooses between NixOS generations.

## The chain

```
power on
  └─ iBoot (Apple)                       picks the volume: Startup Disk, or hold power for the picker
      └─ m1n1 stage 1 on the stub volume  kmutil custom boot object; only reads its config and chains on
          └─ m1n1 stage 2 on the ESP      nvme0n1p4:/m1n1/boot.bin = m1n1 + device trees + U-Boot
              └─ U-Boot                    EFI firmware: NVMe, keyboard, framebuffer
                  └─ systemd-boot          menu of NixOS generations
                      └─ Linux + initrd    root on nvme0n1p5
```

Each stage has its own job, and only stage 1 needs a trip to recoveryOS. Stage 2, U-Boot and the boot menu sit on the ESP, so `nixos-rebuild` (or `just flash-system`) updates them like any other generation.

## What is left to do

| # | Step | Status |
|---|---|---|
| 1 | **m1n1 stage 1**, release build with chainloading: `just m1n1` builds it from the pinned source with m1n1/patches. It gets one config line, `chainload=<nvme0n1p4 PARTUUID>;m1n1/boot.bin`, and is installed on `macostest` from 1TR recoveryOS with `kmutil` (`just m1n1-serve`). | Builds and runs (`tools/m1n1-try`). Not installed: blocked by the ANS sleep crash below. |
| 2 | **Chainloading on M4.** Stage 1 starts stage 2 in place. | Works, and Linux keeps the SSD afterwards (pmp.md) |
| 3 | **m1n1 stage 2 as part of the NixOS system**: `m1n1/boot.bin` = m1n1 + `t6040-j614s.dtb` + U-Boot, written to the ESP by the boot loader (as nixos-apple-silicon's `boot-m1n1` module does with `boot.loader.systemd-boot.extraFiles`). | Not started |
| 4 | **U-Boot for the M4 Pro**: Asahi's U-Boot (`apple_m1_defconfig`) takes its device tree from m1n1. It needs the M4 NVMe changes this kernel needed (controller through ADT reg 9 via the device tree, and the I/O queue registers from Linux commit 304bc392), plus a way to read the keyboard for the menu (the MTP dockchannel HID). | Not started |
| 5 | **EFI kernel and systemd-boot**: `CONFIG_EFI` and `CONFIG_EFI_STUB` in kernel/m4pro-nixos.config, then `boot.loader.systemd-boot.enable = true` with `boot.loader.efi.canTouchEfiVariables = false` in nixos/disk.nix, replacing the extlinux entry. | Not started (`CONFIG_EFI` is off) |
| 6 | **Name in the startup picker**: rename the stub volume in macOS (`diskutil rename macostest NixOS`) so the picker shows NixOS next to Macintosh HD. | Optional |

Steps 1 and 2 decide whether the rest can work, so they come first.

## Findings (2026-11-13)

Tested without recovery trips with `tools/m1n1-try`, which runs an m1n1 image the way stage 1 starts stage 2 (proxyclient `chainload.py -r`: same base, entry 0x800, RVBAR untouched) and shows the new m1n1's log on the debug link.

- **Stage 1 must end its config lines with four NUL bytes**, as asahi-installer `src/m1n1.py` writes them. Without them m1n1 scans past the image for payloads when iBoot loads it; on J614s every such image stopped before drawing its logo, and iBoot fell back to the recovery/startup-disk screen. `m1n1-stage1` in the flake does this now.
- m1n1 is built with gcc 14 and `hardeningDisable = [ "all" ]` (`pkgs/m1n1.nix`), like other firmware in nixpkgs; the code then matches the Docker build except for nixpkgs' appended logo.
- **Chainloading works on T6040.** `m1n1-stage1` (release) initialises ANS through ADT reg 9, finds the ESP by PARTUUID, loads `m1n1/boot.bin` (5373968 bytes) and stage 2 comes up in its proxy.
- **Linux's NVMe fails after any ANS sleep.** m1n1 puts ANS to sleep and resets it after reading the ESP; Linux then cold-boots it and ANS crashes with an SError (FAR 0x41f008000 in ANS's address space, not in the ADT). The same happens with Linux alone: unbinding and rebinding `nvme-apple` makes ANS crash while entering IOP sleep (`NVMe shutdown start ... saveCtx`, AP quiesce acked, then SError at 0x41f020000). Direct boots only work because iBoot leaves ANS running and Linux wakes it instead of cold-booting it. Ruled out: the PMGR reset sequence, `apcie_sys_st0` state, NVMe controller shutdown, and the NVMe/NVMMU/IOQ registers m1n1 leaves set.
- Solved: see pmp.md. PMP is started by Linux, ANS power is reported to it, and both Linux and m1n1 stop M4-class ANS by quiescing it with its CPU running; m1n1 stage 1 then hands over to Linux with the SSD working.

## Stage 1 on T6040 (2026-11-13)

Recorded from iBoot's own serial output, which debug USB carries when the port is switched during boot (`build/catch-boot.sh` style capture), and tested from the host with `tools/stage1-test.py` (calls the installed m1n1's chainload in iBoot's memory layout) and `tools/m1n1-try`:

- **iBoot panics on a boot object of 0x4f0000 bytes or more** (mBoot-20457.41.3); 0x4d0000 boots. m1n1's raw image carries .bss, and the hypervisor's nested-virtualization pages (1 MiB, upstream 84b81988) pushed a chainloading build past that. m1n1 patch 0007 allocates them on the heap: stage 1 is 0x3f0088.
- **iBoot places RTBuddySeg, SEPFW, SEPPatches, uStuff, preoslog and BootArgs directly after the boot object**, where stage 1 copies stage 2. m1n1's built-in chainload moved only SEPFW (upstream fixed chainload.py in 00b78fa6, not chainload.c); m1n1 patch 0008 moves them all.
- Stage 1 hands ANS over quiesced (patch 0005), as M4 needs.
- Not the cause, though tried: nixpkgs' logo payload (dropped anyway), the Nix toolchain, the raw vs Mach-O format (iBoot enters a Mach-O without `__TEXT_BOOT_EXEC` like a raw object; aurora-silicon's padding is for Linux's execute window).

## Choosing an OS

- **macOS or NixOS:** the Apple startup picker (hold the power button at boot) lists every volume with a boot object, so both appear. Startup Disk in macOS, or in the picker, sets the default.
- **Which NixOS generation:** systemd-boot's menu, shown by U-Boot, the same as on any other NixOS machine. Older generations stay on the ESP until garbage collected.
