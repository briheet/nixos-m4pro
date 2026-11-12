# AIC worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The AIC is the third boot driver, after the UART and the watchdog. It is the interrupt controller. Later drivers take their interrupts from it. This log is the host-side work: an OCaml client that repeats `aic23_init` for compatible `aic,3`, over the same proxy as the UART and the watchdog.

The Mac was running macOS the whole time. Nothing here poked the live AIC.

## Hardware

The node is `/arm-io/aic`, compatible `aic,3`. m1n1 selects its `aic3` struct for that compatible. The stub Linux tree calls the same block `apple,t6041-aic3`, `apple,t8122-aic3` at `interrupt-controller@502400000`.

| Fact | Value |
|---|---|
| CPU physical base | `0x502400000` |
| Window size | `0x1cc000` |
| Bus address in the raw ADT `reg` cell | `0x302400000` |
| `aic-iack-offset` | `0x40000` |
| `cap0-offset` | `0x4` |
| `maxnumirq-offset` | `0xc` |
| `extint-baseaddress` | `0x10000` |
| `extintrcfg-stride` | `0x4a00` |
| `intmaskset-stride` | `0x4a00` |
| `intmaskclear-stride` | `0x4a00` |

`0x502400000` is the `IODeviceMemory` address. The raw `reg` cell is the address on the `arm-io` bus. m1n1 translates that before it touches the device, so the client uses the CPU physical address. The stub lists a second register named `event` at `0x502440000`. That is `base + aic-iack-offset`, and it sits inside the live window, so one mapping covers it.

`aic-ext-intr-cfg` in the dump is the hex `ad0103`. That is three bytes, one external interrupt:

| Field | Value |
|---|---|
| Die | 0 |
| IRQ | `0x1ad` |
| Target | 3 |

The config word for that IRQ is `base + 0x10000 + 4 * 0x1ad`, which is `0x5024106b4`. The target occupies bits 3:0 (`AIC23_IRQ_CFG_TARGET`).

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| AIC | `lib/soc/aic.ml` | Capability decode, register map, external-IRQ target update |
| Loopback | `lib/boot/loopback.ml` | `P_MASK32`, the proxy form of m1n1's `mask32` |
| Client | `lib/boot/client.ml` | Seeds a one-die controller and runs `init` |
| Tests | `test/test_nixos_m4pro.ml` | Layout, target nibble, software IRQ, and a rejected IRQ |

`init` does what `aic23_init` does for version 3:

1. `P_READ32` of `cap0` at offset `0x4`. Bits 15:0 are `nr_irq`. Bits 27:24 are the last die, and `nr_die` is that plus one.
2. `P_READ32` of `maxnumirq` at offset `0xc`. Bits 15:0 are `max_irq`. Bits 27:24 are `max_die`.
3. Reject more than 4 dies, or `max_irq` above `0x80 * 32`.
4. Place `sw_set`, `sw_clr`, `mask_set`, and `mask_clr` after the config array. The stride properties from the device tree replace the computed stride. For `max_irq` of `0x400` the computed stride is `0x1280`. This Mac's stride is `0x4a00`.
5. For each external IRQ, `P_MASK32` clears bits 3:0 and sets the target. Other bits in that word stay.

`nr_die` and `nr_irq` are not in the device tree. They are silicon registers. The loopback has no AIC, so the client writes a stand-in before `init`: `cap0 = 0x400` and `maxnumirq = 0x01000400`. That is 1 die and 1024 IRQs, which is large enough for IRQ `0x1ad`. A live proxy reads the real counts instead of planting these.

`set_sw` and `ack` follow `aic_set_sw` and `aic_ack`. `ack` reads `base + 0x40000`.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. The checks cover the base, the decoded external IRQ, the computed stride, and the field extract. After `init`, the config word that was seeded with `0xa0` reads `0xa3`. `set_sw` of IRQ 0 stores 1 at `sw_set`. A controller whose `cap0` says zero IRQs rejects `0x1ad`.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
AIC /arm-io/aic aic,3 base 0x502400000, 1/1 dies, 1024/1024 IRQs
external irq 0x1ad target 3 at 0x5024106b4
```

The `1/1` and `1024/1024` figures are the loopback seed, not a reading from this Mac.

## Still open

A live init has the same requirement as the UART and the watchdog. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

This is the bootloader init. A NixOS kernel driver for `aic,3` is still open. The die and IRQ counts still have to be read from the silicon before the map can be treated as this machine's map.
