# Power manager worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The power manager is the fourth boot driver, after the UART, the watchdog, and the AIC. It gates power to the blocks behind it. This log is the host-side work: an OCaml client that repeats `pmgr_set_mode` from unmodified m1n1, and uses it to turn on the AIC domain.

The Mac was running macOS the whole time. Nothing here poked the live power manager.

## Hardware

The live node is `/arm-io/pmgr`, compatible `pmgr1,t6041`. The registry location is `2800000`. That is the stub tree's `pmgr1: power-management@502800000`, whose compatible is `apple,t6041-pmgr`, `apple,t8103-pmgr`. `die-count` on `/arm-io` is 1.

| Fact | Value |
|---|---|
| CPU physical base | `0x502800000` |
| First window | `0x1e0000` |
| `IODeviceMemory` ranges | 63 |
| Stub window | `0xc000` |

The first `IODeviceMemory` range is the CPU physical base. The stub maps a shorter window at the same address. The two domains used here sit inside both sizes.

The stub attaches the AIC to this block:

| Domain | Offset | Parent | Notes |
|---|---|---|---|
| `ps_pms` | `0x100` | none | `apple,always-on` |
| `ps_aic` | `0x118` | `ps_pms` | the AIC's power domain |

Addresses are `0x502800100` and `0x502800118`.

`devices` (23280 bytes) and `ps-groups` (48 bytes) are stored in the dump only as hashes. `pmgr_init` walks those blobs, so that walk cannot be repeated from the dump.

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| Power manager | `lib/soc/pmgr.ml` | `set_mode` and `power_aic` |
| Loopback | `lib/boot/loopback.ml` | Copies the target power state into the actual field |
| Client | `lib/boot/client.ml` | Powers `ps_pms`, then `ps_aic` |
| Tests | `test/test_nixos_m4pro.ml` | Both domains read back active, and a poll off the window times out |

`set_mode` does what `pmgr_set_mode` does:

1. `P_MASK32` clears `PMGR_AUTO_ENABLE` (bit 28), `PMGR_WAS_CLKGATED` (bit 9), `PMGR_WAS_PWRGATED` (bit 8), and `PMGR_PS_TARGET` (bits 3:0).
2. The same write sets `PMGR_PS_TARGET` to the mode. Active is `0xf`, clock-gate is `0x4`, power-gate is `0x0`.
3. Poll `PMGR_PS_ACTUAL` (bits 7:4) until it holds the same mode shifted up by 4. m1n1 polls 10000 times.

Enabling a device walks its parent first. `power_aic` therefore sets `ps_pms` active, then `ps_aic`.

The loopback copies bits 3:0 into bits 7:4 on every write inside the first window. That is the silicon finishing the transition before the poll. A write outside the window leaves the actual field alone, so the poll fails.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. After `power_aic`, both `0x502800100` and `0x502800118` read `0xff`: target `0xf` and actual `0xf`. `set_mode` of an address outside the window raises `pmgr: timeout`.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
PMGR /arm-io/pmgr pmgr1,t6041 base 0x502800000
powered pms 0x502800100 and aic 0x502800118
```

## Still open

A live power-on has the same requirement as the earlier drivers. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

The rest of `pmgr_init` needs the `devices` and `ps-groups` bytes. Those have to be read from the ADT on a live proxy. A NixOS kernel driver for `pmgr1,t6041` is still open.
