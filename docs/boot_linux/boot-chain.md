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
| 1 | **m1n1 stage 1**, release build with chainloading: `just m1n1` builds it from the pinned source with m1n1/patches. It gets one config line, `chainload=<nvme0n1p4 PARTUUID>;m1n1/boot.bin`, and is installed on `macostest` from 1TR recoveryOS with `kmutil` (`just m1n1-serve`). | Builds. Config line and install not done. |
| 2 | **Chainloading on M4.** Stage 1 starts stage 2 in place. The proxy's `chainload.py` faulted on this Mac (RVBAR is locked once m1n1 has run), so the in-m1n1 chainload path has to be checked on T6040 before anything relies on it. | Not tested |
| 3 | **m1n1 stage 2 as part of the NixOS system**: `m1n1/boot.bin` = m1n1 + `t6040-j614s.dtb` + U-Boot, written to the ESP by the boot loader (as nixos-apple-silicon's `boot-m1n1` module does with `boot.loader.systemd-boot.extraFiles`). | Not started |
| 4 | **U-Boot for the M4 Pro**: Asahi's U-Boot (`apple_m1_defconfig`) takes its device tree from m1n1. It needs the M4 NVMe changes this kernel needed (controller through ADT reg 9 via the device tree, and the I/O queue registers from Linux commit 304bc392), plus a way to read the keyboard for the menu (the MTP dockchannel HID). | Not started |
| 5 | **EFI kernel and systemd-boot**: `CONFIG_EFI` and `CONFIG_EFI_STUB` in kernel/m4pro-nixos.config, then `boot.loader.systemd-boot.enable = true` with `boot.loader.efi.canTouchEfiVariables = false` in nixos/disk.nix, replacing the extlinux entry. | Not started (`CONFIG_EFI` is off) |
| 6 | **Name in the startup picker**: rename the stub volume in macOS (`diskutil rename macostest NixOS`) so the picker shows NixOS next to Macintosh HD. | Optional |

Steps 1 and 2 decide whether the rest can work, so they come first. A stage 2 that just prints and returns to the proxy is enough to test chainloading, and it costs one recoveryOS trip.

## Choosing an OS

- **macOS or NixOS:** the Apple startup picker (hold the power button at boot) lists every volume with a boot object, so both appear. Startup Disk in macOS, or in the picker, sets the default.
- **Which NixOS generation:** systemd-boot's menu, shown by U-Boot, the same as on any other NixOS machine. Older generations stay on the ESP until garbage collected.
