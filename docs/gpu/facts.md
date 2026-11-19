# GPU facts for this J614s (phase 0, docs/gpu/plan.md)

Read on 2026-11-14 with `nixos-m4pro gpu ADT` (the ADT dump) and
`nixos-m4pro gpu-probe` (live, through m1n1's proxy, before Linux ran).
Raw firmware dumps and efuse words stay in `build/agx/`; this file keeps
what the driver work needs.

## Firmware

iBoot loads the GPU firmware for the `gfx-asc` coprocessor from the macOS
27.2 stub volume (`macostest`). Its own strings:

- `RTKit_armv8_lightning_Oz_flto_pac-3514.41.1.release`
- `FW Build variant: g16s`, `FW Build version: b0`, `running in SKSM Enabled mode`
- "Host and FW Interface is mismatched, please ensure the versions are
  aligned." — the firmware checks the host's interface version.

| Segment | phys | coprocessor address | size |
|---|---|---|---|
| `__TEXT` | `0x10000c1c000` | `0x7ffffc0000000000` | `0x64000` |
| `__DATA` | `0x10001ccc000` | `0x7ffffc0000064000` | `0xc4000` |
| `__DATA_SHARED_RO` | `0x10001d90000` | `0x7ffffc0000128000` | `0x8000` |

`__DATA` (md5 `72313499…`) and `__DATA_SHARED_RO` (`bb7df04e…`) were
identical on two boots; `__TEXT` was not (`c18c6a31…`, `6a131092…`), and is
stable within a boot. iBoot changes something in it per boot; which bytes
is the next thing to find (per-run dumps now kept for that). A firmware id
must hash `__TEXT` with those words masked, or `__DATA` plus the strings.

## Hardware

- GPU `gpu,t6040` at `0x288000000` (+`0x3758000`), `gfx-asc` at `0x28a600000`.
- Power: gates `0x190`, `0x192` resolve to PMGR `afr` (`0x288e80100`) then
  `gfx` (`0x288e80110`). Both are power-gated (`0x0f000300`) after boot,
  although the ADT flags `afr` always-on. Reading SGX registers with only
  `gfx` raised hangs the bus; raise `afr` first.
- Core mask (SGX `+0xe01500`): `0x000f6f7b` = cluster 0 `0x37b`, cluster 1
  `0x3db`: **2 clusters × 8 active cores (16)**, 10 slots per cluster.
- Perf map A (SGX `+0xe01400`): states 0 1 2 3 4 6 8 10 12 14 15.
  Perf map B (SGX `+0xe01480`): states 0 1 2 3 4 6 7 9 11 13 15.
  Both 11 entries, rising, ending at 15 (1578 MHz). The ADT perf table is
  two ladders interleaved, which is why it is not sorted.
- Leakage from the efuse page `0x508374000` (`0xc10`..`0xc2b`, aura's
  field layout): all five fields valid.

## Operating points (ADT `/arm-io/sgx`)

15 states (`gpu-num-perf-states`), two tables (`perf-state-table-count`),
MHz/mV, table 0: 338/600 618/635 796/685 924/725 952/765 1056/765
1062/800 1182/800 1182/845 1312/845 1242/900 1380/900 1326/945 1470/945
1578/1030 (plus state 0 off). SRAM tables, and `afr`/`cs` tables of 8
states (24–1470 MHz) in microvolts, are in `nixos-m4pro gpu` output.

## Firmware interface (traced under the hypervisor, macOS 27.2)

`tools/hv/trace_agx_raw.py` (raw capture) and `nixos-m4pro agx …` (offline
decoding, `lib/agx/`). Traces stay in `build/agx/traces/`.

- Mailbox: RTKit HELLO version 12 on endpoint 0, then endpoint 0x20/0x21
  as on M1/M2: one `0x81` message (host → firmware) carries the InitData
  address in bits 47:0, then kicks (`0x83`, `0x84`, `0x87`) on 0x21 and
  pongs (`0x42`) back on 0x20. 46k messages in the first minute of a
  macOS boot.
- GPU address space (UAT): 16 KiB pages, three levels at bits 36/25/14
  with 64/2048/2048 entries, so 42-bit halves; the kernel half is
  `0xfffffc0000000000` and up. InitData declares exactly this.
- Context 0's TTBR1 table is empty: the kernel-half tables live in
  `gfx-shared-region` (root `0x105fff78000`). Its first-level slots:
  0 the firmware (`__TEXT` pages), 1 device registers (`gfx-asc`, SGX),
  2 macOS's GPU allocations (`0xfffffc20…`, in `gfx-shared-l2-region`).
  The firmware maps GPU registers into its space; reading those pages from
  the host crashes the machine, so the tracer reads RAM only.
- InitData (`0xfffffc20000f0000`): same as 13.x up to `0x28`; 13.x's
  `fw_status_addr` pointer is two u32 (0, 1) in 27.2; the UAT description
  follows at the same offset; after the padding, 13.x's five u32 are four
  kernel pointers in 27.2 (`0xa8`–`0xc7`). Schema: `lib/agx/initdata.ml`.
- Region B (`lib/agx/regionb.ml`): a 0x20-byte header, then the 12 queue
  channels (TA/3D/CL × 4) and DevCtrl as 0x20-byte records: pointers to
  three ring counters 0x10 apart (13.x's read pointer at +0 and write
  pointer at +0x20, plus a new one at +0x10), then the ring. 13.x had one
  state pointer per channel (0x10-byte records). The auxiliary channels
  (event, firmware log, trace, stats) follow at 0x1c0 in another shape.
- Queue ring entries are 0x18 bytes (13.x: 0x30): queue type, command
  queue pointer, a constant 1, a u16 event number (+2 per submission), a
  constant 5, and the new-queue flag.
- Command queues (`lib/agx/cmdqueue.ml`): 0x80 bytes each (13.x ~0xb0),
  packed 0x80 apart. Queue pointers, ring and job list where 13.x has them;
  13.x's `gpu_buf` pointer is gone, so the read pointers and `event_id`
  (-1) move up 8 bytes. The queue-pointer block and job list keep their
  13.x layouts (done and read pointers equal when the queue is idle).
- Work commands have new types: a 3D queue's ring alternates type `0xf`
  (0xc0 bytes, pointers at 2-byte boundaries: +0x10 a per-command kernel
  buffer, +0x36, +0x4a a GPU context) and type `0x10` (0x40 bytes, no
  pointers). 13.x used 0 TA, 1 3D, 3 compute, 4 barrier, 6 init-BM.

## Still to collect

- macOS side: `ioreg -l -r -c AGXAccelerator`, `sudo powermetrics
  --samplers gpu_power -n 5` (frequencies against the maps above).
- Which `__TEXT` bytes change per boot.
