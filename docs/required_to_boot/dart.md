# DART worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The DART is the fifth boot driver, after the UART, the watchdog, the AIC, and the power manager. It is the IOMMU. DMA devices behind it cannot be programmed until a stream has a translation table. This log is the host-side work: an OCaml client that repeats the `dart,t8110` register writes from `dart_init` in unmodified m1n1.

The Mac was running macOS the whole time. Nothing here poked a live DART.

## Hardware

Every DART on this Mac is compatible `dart,t8110`. There are 30 of them. The page size in the device tree is `0x4000`, which is the t8110 TTBR shift of 14. `sid-count` is 256. The addresses are the first `IODeviceMemory` range of each node, which is the CPU physical base `adt_get_reg` returns.

| Name | Base | Length |
|---|---|---|
| `dart-isp0` | `0x5828c0000` | `0xc000` |
| `dart-apcie0` | `0x410000000` | `0x20000` |
| `dart-apcie1` | `0x411000000` | `0x20000` |
| `dart-mtp` | `0x514800000` | `0xc000` |
| `dart-apciec0` | `0x384000000` | `0x20000` |
| `dart-acio0` | `0x381a80000` | `0xc000` |
| `dart-apciec1` | `0x38c000000` | `0x20000` |
| `dart-acio1` | `0x389a80000` | `0xc000` |
| `dart-apciec2` | `0x394000000` | `0x20000` |
| `dart-acio2` | `0x391a80000` | `0xc000` |
| `dart-aop` | `0x510f00000` | `0xc000` |
| `dart-sio` | `0x429060000` | `0x20000` |
| `dart-pmp` | `0x500300000` | `0xc000` |
| `dart-sep` | `0x404c80000` | `0x20000` |
| `dart-usb0` | `0x382f00000` | `0xc000` |
| `dart-usb1` | `0x38af00000` | `0xc000` |
| `dart-usb2` | `0x392f00000` | `0xc000` |
| `dart-disp0` | `0x402300000` | `0xc000` |
| `dart-dcp` | `0x402340000` | `0x20000` |
| `dart-dcpext0` | `0x3a2340000` | `0x20000` |
| `dart-dispext0` | `0x3a2300000` | `0xc000` |
| `dart-dcpext1` | `0x602340000` | `0xc000` |
| `dart-dispext1` | `0x602300000` | `0xc000` |
| `dart-scaler0` | `0x521260000` | `0xc000` |
| `dart-ave0` | `0x2830a0000` | `0xc000` |
| `dart-apr0` | `0x301020000` | `0xc000` |
| `dart-jpeg0` | `0x487020000` | `0xc000` |
| `dart-jpeg1` | `0x487080000` | `0xc000` |
| `dart-ane0` | `0x485800000` | `0xc000` |
| `dart-avd0` | `0x281020000` | `0xc000` |

The instance exercised here is `dart-apcie0`. It is the IOMMU for `/arm-io/apcie0`. Wi-Fi's `iommu-parent` is `mapper-apcie0-wlan` (`0x5e`). Bluetooth's is `mapper-apcie0-bt` (`0x5f`). The SD card reader's parent is `mapper-apcie1` (`0x63`), on `dart-apcie1`.

The internal SSD does not use a DART. `/arm-io/ans` has `iommu-parent` `0x124`, and that node is `/arm-io/sart-ans`, compatible `sart,coastguard`. NVMe still needs the SART.

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| DART | `lib/soc/dart.ml` | The 30 bases, TTBR encode, and `init` |
| Loopback | `lib/boot/loopback.ml` | Sets the TLB busy bit, then clears it on the next read |
| Client | `lib/boot/client.ml` | Programs stream 0 of `dart-apcie0` |
| Tests | `test/test_nixos_m4pro.ml` | Register values, a rejected stream, and a locked TTBR |

`init` does the register half of `dart_init` for `DART_T8110`. m1n1 also allocates a 16 KiB page table with `memalign`. This client does not. The caller passes a physical table address that is already 16 KiB aligned. `keep_pts` is not implemented, so the writes match `dart_init` with `keep_pts` false. t8110 has one TTBR.

1. Reject a stream outside `0 .. 255`.
2. Read `PROTECT` at offset `0x200`. Bit 0 means TTBR and TCR are locked.
3. Write `ENABLE_STREAMS` at `0xc00 + 4 * (stream / 32)` with bit `stream mod 32` set.
4. Read the TTBR at `0x1400 + 4 * stream`. Write it when the DART is unlocked, or when the valid bit is clear. The encoding puts `table >> 14` in bits 29:2 and sets bit 0. A table at `0x80000000` encodes as `0x80001`.
5. When the DART is unlocked, write TCR at `0x1000 + 4 * stream` with the translate-enable bit set.
6. Flush that stream. The command register is offset `0x80`. The opcode for flush-SID is bits 10:8 equal to 1, so the low byte of the command is `0x100` or the stream number.

m1n1 then polls `regs + DART_T8110_TLB_CMD_OP`. That macro is the opcode field, value `0x700`, not the command register. The busy bit is bit 31 of the command register at offset `0x80`. The client polls `0x80`. The sources in `upstream/m1n1` were not changed.

The loopback sets bit 31 when the command is written and clears it on the first read. The poll takes two reads and then sees the command without the busy bit.

The table address `0x80000000` is a stand-in so the encode and the store can be checked. It is not a page table built for this Mac, and stream 0 is not a claim about which stream Wi-Fi uses.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. The checks cover the instance count, the `dart-apcie0` base, the TTBR encoding, the four registers written for stream 0, stream 256 being rejected, and a locked DART whose TTBR is already valid. In that last case the TTBR stays at the seeded `0x11` and TCR stays 0.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
DART dart,t8110, 30 instances
dart-apcie0 base 0x410000000 stream 0 table 0x80000000 locked false
```

## Still open

A live init has the same requirement as the earlier drivers. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

The page-table walk is still open. So is the SART in front of the SSD, and a NixOS driver for `dart,t8110` on this SoC.
