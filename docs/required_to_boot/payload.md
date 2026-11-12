# Payload worklog

Date: 2026-11-12. Machine: MacBook Pro 14-inch, M4 Pro, `Mac16,8` / `J614s` / `T6040`.

m1n1 hands the next stage off by scanning the bytes concatenated after `m1n1.bin`. This log is that scan, on the host, for the image `payload_run` accepts and then passes to `kboot_boot`. The Mac was running macOS the whole time. Nothing here jumped to a kernel.

## What m1n1 scans

`payload_run` reads the ADT `target-type`, lowercases it, and prefixes `apple,`. On this board that string is `apple,j614s`. It then walks `_payload_start`.

| Bytes | What the scanner does |
|---|---|
| `1f 8b` | Gzip. Decompress, then recognize the uncompressed bytes. The next outer payload starts after the gzip member |
| `d0 0d fe ed` | Devicetree. Kept when the root `compatible` list contains `apple,j614s` |
| `ARM\x64` at offset `0x38` | ARM64 kernel header. With a known size the scan continues `image_size` bytes later. With an unknown size the scan stops, so a raw kernel hides anything after it |
| `m1n1_initramfs` plus a little-endian u32 | Initrd of that many bytes. `load_cpio` records the range |
| `07070` with a known size | Initrd. With an unknown size the scan stops: `Uncompressed cpio archives not supported` |
| `name=value\n` | `chosen.*`, `chainload=`, `display=`, `mitigations=`, `tso=` |
| four zero bytes, or `IMG4` at offset 5 | End of payloads |

`kboot_prepare_dt` requires a `/memory` node and later rewrites its `reg` from the boot args. `kboot_boot` sets the entry to the kernel and `x0` to the devicetree. The jump itself is back in `m1n1_main`, after `nvme_shutdown`.

## What was built

m1n1 stays a submodule and its sources were not edited. `upstream/linux` stays a gitlink.

| Piece | Path | Role |
|---|---|---|
| Payload | `lib/boot/payload.ml` | Stored-block gzip, a small devicetree, the scanner, and `pack` |
| Client | `lib/boot/client.ml` | Scans one packed image and prints the handoff |

`pack` concatenates `tso=0`, `chosen.nixos-m4pro=handoff`, a gzip of a 64-byte kernel header, a raw devicetree, an `m1n1_initramfs` wrapper around `nixos-m4pro`, and four zero bytes.

The kernel header has `image_size` 64 and magic `0x644d5241` at offset `0x38`. The first instruction is `0x14000000`, which is a branch to itself. The scanner recognizes that header. A T6040 NixOS kernel is the image that would replace it.

The gzip member is one stored deflate block. zlib accepts that member, and the CRC of this header is `0x0a526ae4`. m1n1's `tinf` accepts stored blocks and Huffman blocks. This host reader accepts the stored block this packer writes. A distribution `Image.gz` uses Huffman blocks, and this reader reports `payload: gzip uses a non-stored deflate block`.

The devicetree root is compatible `apple,j614s`, `apple,t6040`, `apple,arm-platform`, which is the list in `configs/devicetree/upstream/t6040-j614s.dts`. The `/memory` node carries the placeholder `reg` from `t604x-j614-j616.dtsi`: `<0x100 0 0x2 0>`. `kboot_prepare_dt` overwrites that property from the live boot args. The model string is `Apple MacBook Pro (14-inch, M4 Pro, 2024)`.

## What was checked

`nix develop -c dune runtest --force` prints `ok`. The packed image scans as a 64-byte kernel, compatible `apple,j614s`, a `/memory` node, initrd of 11 bytes, `tso` clear, and the chosen pair `nixos-m4pro=handoff`. A raw kernel in front of the same devicetree records the kernel and stops before the devicetree. A devicetree whose only compatible string is `apple,t6040` is kept and is not a ready handoff. An uncompressed cpio fails with the m1n1 string. The stored gzip round-trips to the 64-byte header.

`nix develop -c dune exec -- nixos-m4pro` printed:

```text
payload kernel image 64 bytes, fdt apple,j614s, memory true, initrd 11 bytes
kboot entry is that kernel and x0 is the fdt
```

## Still open

A boot of this Mac needs the machine chainloaded into unmodified m1n1, with this payload concatenated after `m1n1.bin`, and the client on a second machine at `/dev/cu.usbmodemP_01`, 115200 baud. This session did not boot the hardware.

`kboot_prepare_dt` rewrites the devicetree from the live ADT: memory from the boot args, plus serial, MAC, SEP, wifi, and the tunable blobs. Those values are not invented here. `kboot_boot` also enables the cache, applies static tunables, and brings up USB, PCIe, and the secondaries before it stores the entry. The host records the entry and `x0`. It does not jump.

There is no T6040 NixOS kernel in this repo. The 64-byte header is the image the scanner recognizes. `nvme_shutdown` runs after a payload is accepted and before the jump. Its `pmgr_reset` of ANS needs the hashed PMGR device blob, so the client leaves the controller enabled. The ANS log has the read and the queue setup that shutdown would tear down.
