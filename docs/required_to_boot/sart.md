# SART worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

The SART is the filter in front of the NVMe coprocessor. It comes after PCIe in the boot list because the internal SSD is not a PCIe endpoint. `/arm-io/ans` names `sart-ans` as its `iommu-parent`. This log is the host-side work: an OCaml client that repeats `sart_init` and `sart_add_allowed_region` from unmodified m1n1 for version 3.

The Mac was running macOS the whole time. Nothing here poked the live SART.

## Hardware

The node is `/arm-io/sart-ans`, compatible `sart,coastguard`, `device_type` `sart`. `sart-version` is 3. The phandle is `0x124`, which is the value in `/arm-io/ans` `iommu-parent`.

The raw `reg` property is a hash. The addresses are the `IODeviceMemory` ranges, which are the CPU physical addresses `adt_get_reg` returns. m1n1 uses index 0 as the register base.

| Index | Address | Length |
|---|---|---|
| 0 | `0x40dc50000` | `0xc000` |
| 1 | `0x40dd44000` | `0x4000` |
| 2 | `0x40dcc0000` | `0x4000` |

`sart-power-managed` is present. `sart-power-reg-offset` is `0x13e8` and `power-canary-offset` is 0. Both sit in the first window. `sart_init` does not write them.

Version 3 has 16 entries. Each entry is three words, in 4 KiB units:

| Word | Offset of entry 0 | Stride |
|---|---|---|
| Flags | `0x00` | 4 |
| Physical address | `0x40` | 4 |
| Size | `0x80` | 4 |

The allow flag is `0xff`. The size field is 30 bits (`GENMASK(29, 0)`) after the 12-bit shift.

## What was built

m1n1 stays a submodule and its sources were not edited.

| Piece | Path | Role |
|---|---|---|
| SART | `lib/soc/sart.ml` | Init, allow, and remove for version 3 |
| Client | `lib/boot/client.ml` | Allows the seven NVMe stand-in pages |
| Tests | `test/test_nixos_m4pro.ml` | Protected entries, alignment, size, and a full table |

`init` reads all 16 config words. m1n1 stores that word in a `u8`, so only the low 8 bits count. A nonzero low byte is marked protected. Later adds and removes skip those entries.

`allow` finds the first entry that is not protected and whose low flag byte is 0. It rejects a range that is not 4 KiB aligned, and a size that does not fit in the 30-bit field. The stores are address, then size, then flags `0xff`, which is the order in `sart3_set_entry`.

`remove` finds the unprotected entry with the same address and size and writes zeros. The client does not allocate the range. The caller passes it, the same way the DART caller passes a page table.

The address `0x80000000` and the size `0x1000` are a stand-in so the encode can be checked. They are not a buffer allocated for this Mac. `protected 0` is the empty loopback: every flag word reads 0, so nothing is protected.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. With entry 0 seeded to flags 1, `init` reports protected mask `0x1` and `allow` uses entry 1. That entry then reads address `0x80000`, size 1, flags `0xff`. Entry 15 seeded with `0x100` stays unprotected, because the low byte is 0. Removing the allowed region clears entry 1 and leaves entry 0 at 1. An unaligned range, a size past the field, a missing remove, and a table whose 16 entries are all protected each fail with the m1n1 message for that case.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
SART /arm-io/sart-ans sart,coastguard version 3 base 0x40dc50000
allowed 7 DMA pages from 0x81000000, protected 0
```

The unit test still allows `0x80000000` size `0x1000` on its own board. The client allows the NVMe queue pages and the read page instead. Those addresses are the stand-ins in `Ans.demo_queues` and `Ans.read_buffer`.

## Still open

A live init has the same requirement as the earlier drivers. This Mac has to be booted into m1n1, and the client has to run on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

The power register at offset `0x13e8` is still unread. The coprocessor behind the filter is logged in `ans.md`.
