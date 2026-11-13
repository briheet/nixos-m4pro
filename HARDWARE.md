# Hardware and support

MacBook Pro (14-inch, M4 Pro, 2024), dumped from macOS on 2026-11-12. This is an inventory of what is in the machine and what the bootloader, the Linux device tree, and the Asahi feature matrix actually cover. Raw dumps are in `configs/`.

When this inventory was taken the machine could not boot NixOS: the Asahi installer does not support it, and the published device tree only describes a small part of the chip. It now runs NixOS from its SSD; see README.md.

## Machine

| | |
|---|---|
| Model | MacBook Pro, `Mac16,8`, model number `MX2H3HN/A` |
| Board | target type `J614s`, Asahi board config `J614sAP`, board-id `0x4` |
| SoC | Apple M4 Pro, chip-id `0x6040` (`T6040`) |
| Linux compatible | `apple,j614s`, `apple,t6040`, `apple,arm-platform` |
| Firmware | mBoot `20457.41.3` |
| macOS | Darwin 27.2.0, `xnu-13432.41.4~25`, kernel config `RELEASE_ARM64_T6041` |
| Disk | `APPLE SSD AP0512Z`, 500.3 GB, GUID + APFS only |
| Linux partition | none |
| Activation Lock | enabled |

`chip-id` is `T6040`, but the live `arm-io` node is `arm-io,t6041` and macOS runs the `RELEASE_ARM64_T6041` kernel. Upstream Linux models the M4 Pro as a cut-down M4 Max (`t6040.dtsi` includes `t6041.dtsi` and deletes blocks).

The internal SSD has the usual macOS containers (ISC, the system container, Recovery) plus an APFS volume named Nix Store (37.4 GB). There is no partition an installer can reuse.

## Hardware in this machine

Names below are the Apple device-tree compatibles from `configs/devicetree/nodes.json`, except where noted.

### CPU and memory

12 cores, one thread each, 16K pages. SME and SME2 are present.

| Cluster | Type | Cores | CPU ids | Apple device tree | m1n1 MIDR name | Linux device tree |
|---|---|---|---|---|---|---|
| 0 | Efficiency | 4 | 0–3 | `apple,sawtooth` | M4 Pro Brava Chop (E core), part `0x54` | `apple,brava-e` |
| 1 | Performance | 4 | 4–7 | `apple,everest` | M4 Pro Brava Chop (P core), part `0x55` | `apple,brava-p` |
| 2 | Performance | 4 | 10–13 | `apple,everest` | M4 Pro Brava Chop (P core), part `0x55` | `apple,brava-p` |

CPU ids 8 and 9 are absent. This is the 12-core bin, not the 14-core M4 Pro.

Performance cores: 192K L1 instruction, 128K L1 data, 16M L2 shared by 4 cores. Efficiency cores: 128K L1 instruction, 64K L1 data, 4M L2. Timebase 24 MHz.

Memory is 24 GB LPDDR5 (`dram-size` `0x600000000`). Usable to macOS is about 23.4 GB.

### What the Apple device tree contains

163 devices sit directly under `arm-io`. The ones that matter for a port:

| Block | Present as | Count / notes |
|---|---|---|
| Interrupt controller | `aic,3` | AIC version 3 |
| Memory controller | `mcc,t6041` | one node |
| Power manager | `pmgr1,t6041` | one node |
| PCIe | `apcie,t6040` | `apcie0`, plus `dart-apcie1` with no `apcie1` device node |
| PCIe for the Thunderbolt/USB4 side | `apciec,t6040` | `apciec0`, `apciec1`, `apciec2` |
| USB | `usb-drd,t6040` | three controllers, `usb-drd0`–`usb-drd2` |
| USB/Thunderbolt PHY | `atc-phy,t6040` | four PHYs, `atc-phy0`–`atc-phy3` |
| DisplayPort alt mode | `atc-dpxbar,t604x`, `atc-dpphy,t602x`, `atc-dpin,t602x` | four crossbars, three PHYs, six inputs |
| Internal display | `disp0,t604x` plus `dcp` (`iop,ascwrap-v6`) | one internal pipe |
| External display | `dispext0,t604x`, `dispext1,t604x` | two external pipes |
| GPU | `gpu,t6040` at `sgx` | 16 cores, Metal 4, reported by macOS |
| NVMe coprocessor | `ans` (`iop,ascwrap-v6`), `sart,coastguard` | drive model above |
| Wi-Fi | `wlan` | Broadcom `14e4:4388`, 802.11 a/b/g/n/ac/ax |
| Bluetooth | `bluetooth,n88` | `BCM_4388C2` over PCIe, firmware `24.2.241.1924` |
| Audio DMA | `admac,t604x` | `admac-base-ns` and `admac-leap-ns` |
| Audio coprocessor | `aop` (`iop,ascwrap-v6`), `iop-audio,controller` | built-in microphone and speakers at 48 kHz |
| Keyboard transport | `dockchannel,t8002`, `mtp` (`iop,ascwrap-v6`), `hid-transport,mux` | built-in keyboard path |
| Keyboard backlight PWM | `fpwm,s5l8920x` | `pwm0` |
| Webcam path | `isp,isp-generic-1` | macOS camera is "MacBook Pro Camera" |
| SMC | `smc` (`iop,ascwrap-v6`) | also `smc-gpio0`, `smctempsensor0` |
| GPIO | `gpio,t8101` | `gpio0`, plus AOP, NUB, and SMC GPIO nodes |
| I2C | `i2c,t8101` | `i2c1`–`i2c4`, `i2c6`, `i2c8` |
| SPI | `spi-1,spimc` and `qspi,qspimc` | `spi2`, `spi4`, `qspi` |
| SPMI | `aapl,spmi` | eight nodes |
| UART | `uart-1,samsung` | `uart0` |
| Watchdog | `wdt,t8101` | one |
| IOMMUs | `dart,t8110` | one per major DMA device |
| Video decoder | `avd,t8103` | `avd0` |
| JPEG | `jpeg,t8101` | `jpeg0`, `jpeg1` |
| Neural Engine | `ane,t8020` | `ane0` |
| Encoder side | `ave2`, `apr,j0` | `ave0`, `apr0` |
| SEP | `iop-sep,ascwrap-v6` | Secure Enclave, Touch ID depends on this |
| Debug trace | `apple-processor-trace,t6040` | one |

macOS also reports the internal panel as a 3024×1964 Liquid Retina XDR at 120 Hz (UI resolution 1512×982), and three Thunderbolt/USB4 receptacles at up to 120 Gb/s. The 14-inch chassis has an HDMI output, a 3.5 mm jack, an SD card slot, speakers, microphones, a webcam, and Touch ID. Those are not separate top-level device-tree nodes; they hang off the display, audio, USB, SMC, and SEP blocks above.

## What supports this hardware

Three sources were checked:

- `upstream/m1n1` at `cf37927d` (`v2.0.0-105-gcf37927d`), the cloned bootloader
- `configs/devicetree/upstream/` from AsahiLinux/linux `7b0c21fc` (`arm64: dts: apple: Add minimal t604x (M4 Pro/Max) device trees`). The linux repo is registered as a submodule and is not checked out
- [Asahi M4 feature support](https://github.com/AsahiLinux/docs/blob/main/docs/platform/feature-support/m4.md), read from `main` on 2026-11-12

NixOS Apple Silicon packages follow that Asahi stack. There is no separate NixOS enablement for `Mac16,8`.

### m1n1

The bootloader recognizes this chip. It does not set up a laptop on it.

| Area | In this checkout | Matches this machine |
|---|---|---|
| Chip id and board id | read from the Apple device tree in `src/main.c` | yes, `0x6040` / `0x4` |
| Early UART address | `0x429200000` when built with `TARGET T6040` or `T6041` (`src/soc.h`) | address only; not verified on this board |
| Secondary CPUs | `T6040` uses the same start offset as `T6031` (`src/smp.c`) | yes |
| CPU identification | MIDR parts `0x54` and `0x55` named as M4 Pro Brava Chop. The chicken-bit init pointer is `NULL` (`src/chickens.c`) | name only, no M4-specific chicken init |
| cpufreq | three clusters, `ECPU0`, `PCPU0`, `PCPU1`, plus APSC and PLL relock (`src/cpufreq.c`) | yes, matches the 4E+4P+4P layout |
| Memory controller | `mcc,t6041` calls `mcc_init_t604x` (`src/mcc.c`) | yes, the live node is `mcc,t6041` |
| PCIe | `apcie,t6040` is initialized with the M4 (`t8132`) register set (`src/pcie.c`) | yes for `apcie0` |
| Thunderbolt PCIe | `kboot.c` walks `/arm-io/apciecN` | path walk only; no `apciec,t6040` init in `pcie.c` |
| GPU handoff | core-count and power tables stop at M1/M2-class chips (`src/kboot_gpu.c`). `T6040` hits the unsupported-chip path | no |
| USB, DCP, SMC, audio, Wi-Fi, NVMe, MTP | no `t6040` compatible in those drivers | no |

`T6041` is only partly covered next to `T6040`. SMP knows it. The cpufreq cluster table does not: `cpufreq_get_clusters()` has no `T6041` case and prints "Chip 0x%x is unsupported". This machine's chip-id is `T6040`, so that particular gap does not apply here. The `arm-io,t6041` compatible string does not change the chip-id.

### Linux device tree

`t6040-j614s.dts` is the board file for this exact laptop. It includes `t6040.dtsi` and `t604x-j614-j616.dtsi`, sets the model string, and deletes three external-display power domains.

What that tree actually contains:

| Described | Not described |
|---|---|
| 4× `apple,brava-e` and 12× `apple,brava-p` (the full M4 Max set; the two missing P cores on this 12-core chip are not deleted) | GPU, DCP, USB, Thunderbolt, PCIe, NVMe |
| 24 MHz reference clock | Wi-Fi, Bluetooth, audio, SMC, SPMI, SPI |
| Power-manager nodes and the large `t6041-pmgr.dtsi` power-domain list | Keyboard transport, trackpad, battery, Touch ID, webcam |
| A few `apple,t6041-i2c` controllers | Internal panel timing and brightness |
| One PWM, one UART, AIC3, pin controllers, watchdog | |
| ARMv8 timer | |
| Laptop chassis, a disabled placeholder framebuffer, a keyboard-backlight LED on `fpwm0`, a placeholder `memory` node | |

The framebuffer `reg` is `<0 0 0 0>` and the memory `reg` is a placeholder. Both say "to be filled by loader". m1n1 on older machines does that fill-in. Nothing here shows that fill-in working for `J614s`.

Asahi's own matrix calls the M4 Pro/Max device tree **WIP**, not done. The base M4 (`T8132`, a different chip, used in the M4 MacBook Pro and MacBook Air) is further along: its device tree is listed as `linux-asahi (7.4)`. That status does not apply to this `T6040`.

### Asahi feature matrix for this laptop

For SoC `T604x`, from the M4 feature page:

| Block | Status |
|---|---|
| Video decoder, NVMe | WIP |
| AIC v3 | WIP |
| DCP, USB2, USB3, Thunderbolt, DisplayPort alt mode, GPU, PCIe, cpufreq, cpuidle, suspend | TBA |
| Video encoder, ProRes, DART, PMU, UART, watchdog, I2C, GPIO, USB-PD | TBA |
| Audio DMA, SPI, SPI NOR, SMC, SPMI, RTC, SEP, Neural Engine | TBA |

For the MacBook Pro 14-inch and 16-inch, M4 Pro/Max, 2024:

| Feature | Status |
|---|---|
| Installer | no |
| Device tree | WIP |
| Main display, keyboard, keyboard backlight, trackpad, brightness, battery | TBA |
| Wi-Fi, Bluetooth, HDMI, 3.5 mm jack, speakers, microphones, webcam, SD card, Touch ID | TBA |

The page's note says many of those peripherals depend on DART and PCIe, and both of those are TBA for `T604x`.

### Per-device gap

| Hardware we have | m1n1 `cf37927d` | Linux tree `7b0c21fc` | Asahi matrix for this laptop | Left to do |
|---|---|---|---|---|
| 12 CPU cores | SMP offset and cpufreq clusters | CPUs described, but as 4E+12P | cpufreq and cpuidle TBA | Describe this bin. Confirm secondary CPUs actually start |
| 24 GB LPDDR5 | memory controller init for `mcc,t6041` | memory node is a placeholder | not a separate row | Loader must fill the real memory range |
| AIC v3 | not a T6040 driver | `apple,t6041-aic3` node | WIP | Finish the interrupt controller |
| UART | early base address | `serial0` enabled | TBA | Only useful for a debug console |
| Watchdog, I2C, GPIO, PWM | generic older compatibles exist; no T6040 work found | nodes exist (`wdt`, a few `i2c`, `pinctrl`, `fpwm`) | TBA on T604x | Drivers exist for older chips; bindings for this SoC are not accepted as done |
| PCIe `apcie0` | init path, using M4 register data | absent | TBA | Needs a device tree and a kernel driver, not just bootloader init |
| Thunderbolt PCIe `apciec0`–`2` | path name only | absent | TBA | New init plus a driver |
| USB and DisplayPort alt mode | no | absent | TBA | Blocked on PCIe, DART, and the PHY |
| Internal display | no DCP/GPU support | placeholder framebuffer | TBA | Boot framebuffer, then the real panel |
| 16-core GPU `gpu,t6040` | unsupported chip in GPU handoff | absent | TBA | Bootloader handoff and a kernel driver |
| NVMe | no | absent | WIP | The disk is invisible until this lands |
| Wi-Fi `14e4:4388` and Bluetooth `BCM_4388C2` | no | absent | TBA | Needs PCIe plus firmware extraction |
| Speakers, microphone, headphone jack | no | absent | TBA | AOP and `admac,t604x` |
| Keyboard and trackpad | no | backlight LED only | TBA | MTP / HID transport |
| Brightness, battery | no | absent | TBA | SMC and the panel controller |
| Webcam | no | absent | TBA | ISP |
| HDMI, SD card | no | absent | TBA | Hang off USB/PCIe and the external display pipes |
| Touch ID / SEP | no | absent | TBA | SEP is not supported on any Asahi machine as a login device |
| Video decoder, JPEG, Neural Engine, encoder | no | absent | decoder WIP, the rest TBA | Not needed to reach a console |
| Installer and NixOS module | — | — | installer is no | No supported way to put m1n1 stage 1 on the machine. Activation Lock is also on |

## How much work is left

The identification work is done. A bootable system is not started.

Already in hand:

- The machine is identified, and the Apple device tree, kext list, and profiler dump are in `configs/`.
- m1n1 can name the chip, start secondary CPUs, program the three cpufreq clusters, init the memory controller, and init `apcie,t6040`.
- A minimal device tree exists for `J614s` and builds on the M4 Max tree.

Still required before a serial or framebuffer boot is a reasonable goal:

1. Turn off Activation Lock. The Asahi install path cannot run while it is on.
2. An installer, or an equivalent signed m1n1 stage 1. Asahi lists this as no.
3. A device tree for this 12-core, 16-GPU bin, with real memory and a framebuffer filled in by m1n1.
4. NVMe, which is only WIP, so the internal disk is not a boot target yet.
5. AIC brought up far enough for a kernel to boot. That is WIP, and the T604x watchdog, UART, I2C, and GPIO rows are still TBA.

Still required before the machine is usable as a laptop, all currently TBA: the internal display beyond a dumb framebuffer, keyboard, trackpad, brightness, battery, USB, Thunderbolt, Wi-Fi, Bluetooth, speakers, microphone, headphone jack, webcam, HDMI, and the SD card. GPU acceleration is a separate TBA after the framebuffer. Touch ID is not part of any current Asahi release.

NixOS work sits on top of that and is the small part. Once the Asahi installer, m1n1, U-Boot, and kernel can boot this board, the NixOS piece is a module and a disk layout. That module does not exist, and writing it first would not boot this Mac.
