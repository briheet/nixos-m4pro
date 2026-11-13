# Required for daily use

Everything that has to work before NixOS is a daily driver on this MacBook Pro (14-inch, M4 Pro, `Mac16,8`, `J614s`, `T6040`), in the order it can be done. `docs/required_to_boot/` covers the seven drivers for a first shell. This list starts there and goes up to a laptop that installs, boots from its own disk, and runs a desktop.

Hardware names come from this Mac's Apple device tree, read through m1n1 on 2026-11-12. Asahi status is the `T604x` column of the [M4 feature page](https://github.com/AsahiLinux/docs/blob/main/docs/platform/feature-support/m4.md), as recorded in `HARDWARE.md`. "Here" is what this repo has done on the live machine.

## What is already in hand

- m1n1 (`cf37927d` plus m1n1/patches, development build) is the custom boot object on the `macostest` volume. `Macintosh HD` is untouched and stays at Full Security.
- The host (an M5 Max) reaches m1n1's proxy over debug USB at `/dev/cu.kis-100000-ch-0` after `macvdmtool debugusb`. Serial mode is refused.
- Read, write, power, and interrupt-routing steps for the UART, watchdog, PMGR, and AIC run on the live board through `nixos-m4pro`.

## The list

| # | Item | Hardware on this Mac | Asahi | Here |
|---|---|---|---|---|
| **Phase 1: a shell from RAM** | | | | |
| 1 | Linux build environment | aarch64-linux builder on the host | — | Done: `just builder`, Nix in an aarch64-linux container |
| 2 | Kernel boots to a serial shell, tethered from the host | m1n1 proxy, `uart0` | Device tree WIP | Done: console on `ttyDC0` (dockchannel) |
| 3 | Device tree for this bin | 4E + 8P cores, 24 GB, `J614s` | WIP, lists 4E + 12P | Done: `t6040-j614s.dts`, 12 cores, 24 GB |
| 4 | Interrupts, timers, secondary CPUs | `aic,3`, ARM timer, 3 clusters | AIC v3 WIP | Done: AIC, timer, all 12 cores (both CTRR ranges reserved in m1n1) |
| 5 | Power domains, watchdog, pinctrl, I2C, SPMI | `pmgr1,t6041`, `wdt,t8101`, `gpio,t8101`, `i2c,t8101`, `aapl,spmi` | TBA | Done: PMGR from the ADT, watchdog reboot |
| 6 | Boot framebuffer on the internal panel | `disp0,t604x`, iBoot framebuffer | — | Done: simpledrm console on the panel |
| 7 | NixOS from RAM | — | — | Done: `just boot-ram` |
| **Phase 2: install to the SSD** | | | | |
| 8 | NVMe | `ans` (`iop,ascwrap-v6`, with an `ans-pcie` child), `sart,coastguard` | WIP | Done: ANS through ADT reg 9, mainline M4 driver change |
| 9 | Disk layout | 500 GB `APPLE SSD AP0512Z`, APFS only | — | Done: p4 `nixos-boot`, p5 `nixos` after a macOS resize; `just flash` |
| 10 | Boot chain from disk | m1n1 stage 1 → stage 2 → U-Boot → extlinux | Installer: no | Done: boots from power-on without the host; keyboard in U-Boot left (docs/boot_linux/boot-chain.md) |
| 11 | Firmware from macOS | Wi-Fi, Bluetooth, and other blobs | — | Trackpad, Wi-Fi and Bluetooth firmware pinned by hash (pkgs/j614s-firmware.nix), converted on a Mac (tools/brcm-firmware) |
| 12 | NixOS module for `J614s` | — | — | nixos/common.nix, disk.nix, ram.nix |
| **Phase 3: a usable laptop** | | | | |
| 13 | Keyboard and trackpad | `mtp` coprocessor, `dockchannel-mtp`, `hid-transport,mux` | TBA | Done: keyboard and multitouch trackpad (docs/boot_linux/keyboard.md); no Force Touch haptics yet |
| 14 | Internal display | `dcp`, `disp0,t604x`, Parade `DP855` TCON on `spi4` | TBA | Not started |
| 15 | Battery, charger, power button, lid | `smc` coprocessor, `smc-gpio0` | TBA | Done: SMC (macsmc) with RTC, battery/AC, power button and lid, clean reboot/power-off; PMU boot counters cleared on each boot (kernel patch 0025) |
| 16 | Keyboard backlight | `fpwm0` | TBA | Not started |
| 17 | CPU frequency, idle, suspend | 3 clusters, PMGR | TBA | Idle: cores sleep in WFI with their registers saved (kernel patch 0024); m1n1 programs the clusters; no cpufreq or suspend yet |
| 18 | USB-C data and charging | `usb-drd,t6040` ×3, `atc-phy,t6040` ×4, `usbc,sn201202x` on SPMI | TBA | Not started |
| **Phase 4: networking** | | | | |
| 19 | PCIe and DART for `apcie0` | `apcie,t6040`, `dart,t8110` | TBA | Done: m1n1 trains the link, Linux runs port 0 (patch 0028); the SError was Linux powering off the unused-looking apcie_sys_gp domain |
| 20 | Wi-Fi | Broadcom `14e4:4388` behind `apcie0` | TBA | Done: BCM4388 C2, firmware from macOS (tools/brcm-firmware), scans and NetworkManager (patches 0029-0031) |
| 21 | Bluetooth | `BCM_4388C2`, `bluetooth,n88` behind `apcie0` | TBA | hci0 comes up (hci_bcm4377); pairing untested |
| **Phase 5: the rest** | | | | |
| 22 | Speakers | 6 × `sn012776` amps on `i2c1`/`i2c3`, `admac,t604x` | TBA | Not started |
| 23 | Headphone jack | `cs42l84` on `i2c2` | TBA | Not started |
| 24 | Microphones | `aop` coprocessor | TBA | Not started |
| 25 | GPU acceleration | `gpu,t6040`, 16 cores | TBA | Not started |
| 26 | HDMI and external displays | `dcpext0`/`dcpext1`, `atc*-dpxbar`, DP alt mode | TBA | Not started |
| 27 | Thunderbolt / USB4 | `apciec0`–`2`, `acio0`–`2` | TBA | Not started |
| 28 | Webcam | `isp0` | TBA | Not started |
| 29 | SD card reader | `sd-card` on `i2c4`, `apcie1` | TBA | Not started |
| 30 | Touch ID | `biosensor,mesa` on `spi2`, `sep` | Not on any Asahi Mac | Out of scope |

## Phase 1: a shell from RAM

### 1. Linux build environment

The host is `aarch64-darwin`. The kernel, the initramfs, and NixOS need an `aarch64-linux` builder: a Nix Linux builder VM, or the Docker VM already used for m1n1.

### 2. Kernel boots to a serial shell

A kernel, this board's device tree, and a small initramfs, sent from the host through m1n1's proxy and started with m1n1's kernel boot path. The console is `uart0`, which is the same line as the debug USB channel. This is the shortest loop for every later kernel item, so it comes first. How fast the proxy moves data over debug USB decides whether each try is uploaded or has to be installed through recovery.

### 3. Device tree for this bin

`t6040-j614s.dts` in AsahiLinux/linux `7b0c21fc` builds on the M4 Max tree. It lists 12 P cores; this machine has 8 (CPU ids 8 and 9 are absent, 10–13 are present). Memory and the framebuffer are placeholders that m1n1 fills.

### 4. Interrupts, timers, secondary CPUs

AIC v3, the ARM generic timer, and starting the other 11 cores. Live: CAP0 is `0x00080aa0` and MAXNUMIRQ `0x02001000` (2720 IRQs on 1 die, room for 4096 on 2), and IRQ `0x1ad` is routed to target 3.

### 5. Power domains, watchdog, pinctrl, I2C, SPMI

The SoC plumbing every later driver sits on. Drivers exist for older Apple chips. Each needs its `T6040` binding checked on this board.

### 6. Boot framebuffer

iBoot leaves the panel lit with a framebuffer, and m1n1 draws on it. Passing it to Linux as a simple framebuffer gives a screen console before any display driver.

### 7. NixOS from RAM

A NixOS closure packed as the initramfs, booted the same way as item 2. Proves the userspace side before the disk is usable.

## Phase 2: install to the SSD

### 8. NVMe

The SSD sits behind the `ans` coprocessor and the SART. The device tree shows an `ans-pcie` child with compatible `apciec,t8103` under `ans`, which older Macs do not have.

### 9. Disk layout

The SSD is one APFS container with no free space for Linux. Making room means shrinking the APFS container that holds `Macintosh HD`. That is the one step in this list that can lose personal data, so it waits for a backup and for the owner's go-ahead.

### 10. Boot chain from disk

m1n1 stage 1 in the stub volume, then stage 2 (m1n1 + device tree + U-Boot) on the ESP, and U-Boot's extlinux menu for NixOS generations. Working since 2026-11-13. Left: the internal keyboard in U-Boot (MTP), so the menu can be used on the Mac itself.

### 11. Firmware

Wi-Fi, Bluetooth, and other blobs are extracted from macOS. They cannot be shipped in the repo.

### 12. NixOS module

A board module: kernel package and config, m1n1 and U-Boot packages, the device tree, firmware, and an installer image. nixos-apple-silicon does this for supported Macs; `J614s` is not one of them.

## Phase 3 to 5

Each needs a kernel driver for this SoC, and most need a coprocessor protocol (RTKit) or firmware on top. On this Mac the USB-C controllers are `sn201202x` on SPMI, not the I2C controllers older Macs use. The speakers are six `sn012776` amplifiers. PCIe devices also need the `apcie0` DART, which raised an SError on a read even with all ten `apcie0` power domains on; m1n1 brings up PCIe before touching it.

## Scale

Items 2–7 and 12 are integration work this repo can do on the live machine. Items 4, 5, 8, 13, 14, 15, 18, 19, 22, and 25 are driver bring-up for a new SoC. Asahi has done that work for older chips over several years, and lists every one of them as WIP or TBA here.

The m1n1 tree carries a notice that its maintainers do not accept AI-assisted work. Nothing written here is prepared as a contribution to Asahi projects.
