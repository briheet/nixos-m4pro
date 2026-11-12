# Drivers required to boot

These seven drivers are required before NixOS can reach a shell on this MacBook Pro (14-inch, M4 Pro, `Mac16,8`, `J614s`, `T6040`). None of them work on this chip today.

The Apple device tree has 163 devices under `arm-io`. These seven are the ones a kernel needs in order to get a serial console and mount the internal SSD.

| Driver | Hardware on this Mac | Status |
|---|---|---|
| AIC v3 | `aic,3` | WIP. A node is in the stub tree |
| Power manager | `pmgr1,t6041` | Node only |
| Watchdog | `wdt,t8101` | Node only. Without it the Mac reboots during boot |
| UART | `uart0` | Node only. This is the first console |
| DART | 30 `dart,t8110` nodes | Missing. Every DMA device needs it |
| PCIe | `apcie,t6040` | Bootloader init only. No kernel driver |
| NVMe | `ans` plus `sart,coastguard` | WIP, and not in the device tree. This is the 500 GB SSD |

## AIC v3

Interrupt controller at `aic,3`. Every other driver needs it. The stub device tree has an `apple,t6041-aic3` node. Asahi marks AIC v3 for `T604x` as WIP.

## Power manager

`pmgr1,t6041`. Gates power to the other blocks. The stub tree has power-manager nodes and `t6041-pmgr.dtsi`. No working driver for this SoC.

## Watchdog

`wdt,t8101`. The stub tree has a watchdog node. If this driver is not built in, the machine reboots during boot.

## UART

`uart0`, compatible `uart-1,samsung`. The stub tree enables `serial0`. This is the first console. A display driver is not required to reach a shell.

## DART

One driver, 30 `dart,t8110` instances, one per DMA device. Missing. NVMe, USB, display, and audio cannot move data without it.

## PCIe

`apcie,t6040` (`apcie0`). m1n1 has a bootloader init path that reuses the base-M4 register set. There is no kernel driver and no node in the stub device tree. The internal SSD is attached through this bus.

## NVMe

The coprocessor `ans` and `sart,coastguard`. The drive is `APPLE SSD AP0512Z`, 500.3 GB. Asahi marks NVMe for `T604x` as WIP, and the stub device tree does not describe it.
