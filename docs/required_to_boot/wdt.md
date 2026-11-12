# Watchdog worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The watchdog is the second boot driver, after the UART. If it stays armed, the Mac reboots during boot and the later drivers never get a stable machine. This log is the host-side work: an OCaml client that repeats `wdt_disable` from unmodified m1n1, over the same proxy the UART client uses.

The Mac was running macOS the whole time. Nothing here poked the live watchdog.

## Hardware

The node is `/arm-io/wdt`, compatible `wdt,t8101`, `wdt-version` 2. The raw ADT `reg` property in the dump is 80 bytes and was stored only as a hash, so the addresses below are the `IODeviceMemory` ranges. Those are the CPU physical addresses `adt_get_reg` returns. Five ranges, in index order:

| Index | Address | Length | Used by `wdt_disable` |
|---|---|---|---|
| 0 | `0x50836c000` | `0x4000` | Primary window. Control register is at offset `0x1c` |
| 1 | `0x508338260` | 4 | Left alone |
| 2 | `0x508330008` | 4 | Second watchdog. Version 2 stores 0 at this address |
| 3 | `0x50833002c` | 4 | Left alone |
| 4 | `0x508330020` | 4 | Left alone |

The stub Linux tree lists only range 0, as `watchdog@50836c000` with compatible `apple,t6041-wdt`, `apple,t8103-wdt`. The version-2 second watchdog is in the live tree and in m1n1, and it is absent from that stub.

Offsets inside the primary window match the macros in `upstream/m1n1/src/wdt.c`:

| Register | Offset |
|---|---|
| `WDT_COUNT` | `0x10` |
| `WDT_ALARM` | `0x14` |
| `WDT_CTL` | `0x1c` |

## What was built

m1n1 stays a submodule and its sources were not edited. `main.c` already calls `wdt_disable()` when m1n1 itself starts. The host program issues the same stores, so the sequence can be checked without a reboot.

| Piece | Path | Role |
|---|---|---|
| Watchdog | `lib/soc/wdt.ml` | The five ranges, `disable`, and the reboot stores |
| Client | `lib/boot/client.ml` | Calls `disable` on the loopback and prints both controls |
| Tests | `test/test_nixos_m4pro.ml` | Disable clears range 0 and range 2, and leaves range 4 |

`disable` does what `wdt_disable` does for version 2 or 3:

1. `P_WRITE32` of 0 to `0x50836c01c` (primary base plus `WDT_CTL`).
2. `P_WRITE32` of 0 to `0x508330008` (range 2, no offset).

`reboot` does what `wdt_reboot` does: store `0x100000` at `WDT_ALARM`, store 0 at `WDT_COUNT`, store 4 at `WDT_CTL`. The tests call it. The running client does not. On a real proxy those three stores reset the machine.

The loopback from the UART work already keeps ordinary `P_WRITE32` values, so the watchdog needed no new framing and no m1n1 change.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. The new checks are: version is 2, five ranges, primary `0x50836c000`, secondary index 2 at `0x508330008`. The test seeds the control register and range 2 with 1, and range 4 with 7. After `disable`, the two controls read 0 and range 4 still reads 7. After `reboot`, alarm is `0x100000`, count is 0, and control is 4.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
WDT /arm-io/wdt wdt,t8101 version 2
primary 0x50836c000, control 0x50836c01c, secondary 0x508330008
watchdog controls 0 0
```

## Still open

A live disable has the same requirement as the UART. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

This is the bootloader disable sequence. A NixOS kernel driver for `wdt,t8101` is still open. The stub device tree still needs the four single-word ranges before that driver can see the second watchdog.
