# agx27: host-side GPU firmware boot for macOS 27.2 (draft)

Phase 3 of [docs/gpu/plan.md](../../docs/gpu/plan.md): boot the J614s's GPU
firmware (T6040, `g16s b0`, from the macOS 27.2 stub) from the host over
m1n1's proxy, the way `upstream/m1n1/proxyclient/experiments/agx_boot.py` and
`m1n1/agx/` do for 13.x firmware. **Nothing here has run on hardware.**

| File | What |
|---|---|
| `layouts.py` | 27.2 structures, transcribed from `lib/agx/*.ml`, offsets asserted against the decode's anchors; `TODO` where undecoded |
| `build_initdata.py` | ADT → InitData / RegionB / HwDataB bytes for the M4 Pro; offline self-test against the macOS snapshot |
| `snapshot.py` | Python reader for `trace_agx_raw.py` snapshots (twin of `lib/agx/snapshot.ml`), incl. raw PTEs |
| `agx27_boot.py` | the boot sequence below as a proxyclient script; refuses to run unless armed; **not** expected to boot yet |

Self-test (offline, no device):

```
.venv-m1n1/bin/python tools/agx27/build_initdata.py
```

## Boot sequence

Each step: what 27.2 needs, what it replaces in m1n1 (13.x), where the
layout comes from.

1. **Power: afr, then gfx.** `p.pmgr_adt_power_enable("/arm-io/sgx")`
   (gates 0x190 `afr` at 0x288e80100, then 0x192 `gfx` at 0x288e80110) and
   `/arm-io/gfx-asc`. `afr` is power-gated after boot although the ADT says
   always-on; SGX access with only `gfx` up hangs the bus
   (`lib/boot/gpu_probe.ml`, `with_chain_active`). m1n1: `agx_boot.py`'s two
   `pmgr_adt_power_enable` calls; check m1n1 raises `afr` (parent) first, or
   do it by hand as `with_chain_active` does. 13.x's `poke_sgx`
   (`+0xd14000 = 0x70001`) is not known to be needed on G16: leave it out.

2. **Identity checks.** Perf maps live at SGX `+0xe01400/+0xe01480` must equal
   `PSTATE_MAP_T6040` (`build_initdata.read_pstate_maps`). Firmware: the
   `ver_info` we send is the 27.2 fingerprint `0x0c8b6339839804c0`; a
   different firmware rejects it ("Host and FW Interface is mismatched").
   No m1n1 equivalent (13.x hardcodes `ver_info` per `Ver`).

3. **UAT.** Same model as m1n1 `hw/uat.py` with `UAT_L0_OFF = 42` (G15+):
   16 KiB pages, levels 36/25/14 with 64/2048/2048 entries, kernel half
   `0xfffffc0000000000`+. TTBR pairs per context at `gpu-region-base`;
   kernel TTBR1 root is iBoot's table in `gfx-shared-region`
   (`0x105fff78000`): L1 slot 0 = firmware `__TEXT`, 1 = device registers,
   2 = macOS's objects (`0xfffffc20_0..` to `0xfffffc30_0..`, table in
   `gfx-shared-l2-region`). m1n1 `UAT.init()` zeroes slots 2.. and keeps
   0/1, then sets ctx 0 under the handoff lock (`gfx-handoff-base`; 13.x
   layout assumed, unverified for 27.2). PTE attributes macOS used (from
   the snapshot, `snapshot.py` `pte()`):
   - objects: `0x..44b` + OS (bit 55) [+ UXN]: AttrIndex 2 (Shared), AP=1, AF;
   - HwDataB/RegionB block and hw rings: `0x..443`: AttrIndex 0 (Normal);
   - io_mappings: `0x..447` + OS + UXN: AttrIndex 1 (Device).

4. **Allocate and fill** (m1n1 `agx/initdata.py: build_initdata`, `CHIP_INFO`):
   - **HwDataB** (0x2850, `layouts.HwDataB27` = `lib/agx/hwdata.ml`): now at
     RegionB+0 (13.x: RegionB+0x1a0, 0xb80 bytes). Built by
     `build_initdata.build_hwdata_b` from the ADT: 11 pstates chosen by
     `pstate_map[0]`, 16 voltage columns (0/1 = ADT tables 0/1, rest = col 0),
     SRAM voltages from `perf-states-sram`, the alternate curve
     (`pstate_map[1]`, `frequencies_alt`, and the second full table with
     only columns 0/1 filled), `rel_boost_freqs` (f32), AFR 8 states
     (µV→mV, SRAM = max(v, 810)); io_mappings: 25 live slots of 60, indexed
     by `kAGFIPIORegionType` id, phys/size/range/flags from the snapshot
     (`IO_MAPPINGS_T6040`), `sgx_offset = phys − 0x288000000` on the 12 slots
     macOS marks (not PMPDoorbell/GFXCLKGENMGPU). VAs from macOS's
     allocator rule (slot order, page offset kept, +16K guard, 32K
     alignment: reproduces all 25 macOS VAs). `sgx_sram_ptr` maps phys
     **0x288d60000** (0x8000, Shared) — found by walking the snapshot's
     tables. Head (+0..+0x640) has exactly 13.x's ≥13.0b4 shape
     (`unk_8..unk_30`, `timestamp_region_base` at +0x28, 63 YUV matrices);
     taken from the snapshot.
   - **RegionB** (`layouts.RegionB27`): 0x20 header (HwDataB ptr, two
     pointers to HwDataB+0xc880, 0), 13 channel records
     {read, +0x10, write counter pointers; ring}. Counter blocks per kind
     (TA +0, 3D +0x100, CL +0x200, 0x40 per queue, queues reversed), rings of
     0x100 × 0x18-byte `RunCmdQueueMsg27`. m1n1: `init_channels` +
     `ChannelInfoSet` (13.x: 17 × {state, ring}).
   - **InitData** (`layouts.InitData27`, 0xc8: the firmware copies 0xc8 bytes):
     fingerprint, RegionA +0x8, RegionB +0x18, RegionC +0x20,
     `+0x2c = 1` (host-mapped FW allocations; firmware refuses 0), UAT
     description at +0x30 (identical to 13.x), four new pointers
     +0xa8..+0xc0. 13.x's `fw_status` pointer is gone.
   - **RegionA, RegionC, +0xa8/+0xb0/+0xb8/+0xc0 targets**: not decoded
     (see Gaps). Minimum sizes from the firmware's reads in `layouts.py`.

5. **RTKit**: start `gfx-asc`, HELLO (version 12 seen under macOS), start
   EP 0x20 and 0x21 (m1n1 `AGX.resume`; unchanged).

6. **InitData message**: type 0x81 on EP 0x20, the VA in bits 47:0
   (`build_initdata.msg_initdata`); the firmware ORs in
   `0xfffff00000000000` (fn_32224), so the VA must lie in the kernel half.
   m1n1's `InitMsg` has a 44-bit field (`INITDATA = 43, 0`): send the raw
   48-bit message instead. macOS: `0x0081fc20000f0000`.

7. **Expected responses.** Under macOS: pongs (type 0x42) on EP 0x20 and
   kicks (0x83/0x84/0x87) on 0x21. Failures we can recognise: the two log
   strings in step 2/4 (`ver_info`, `+0x2c`). 13.x's next steps
   (`DC_Init`, `DC_UpdateIdleTS` on the device-control channel) have no
   27.2 layout yet. m1n1's `FirmwareEP` 0x42 handler calls
   `agx.poll_channels()`: give it a stub.

## Self-test result (2026-11-14)

`build_initdata.py` vs. macOS HwDataB at `0xfffffc20c07a0000` in
`27.2-boot5/03-after-5000-msgs`:

- With our own VAs: 41 of 0x2850 bytes differ, all in pointer fields
  (`timestamp_region_base`, 25 `io_mappings.*.virt_addr`, `sgx_sram_ptr`,
  hw ring VAs, `counter_ctl`, `unk_27e0`), plus the two below.
- With macOS's VAs plugged in: **3 bytes** differ: `hw_rings[0].fw_state`
  (0x601, written by the firmware) and `rel_boost_freqs[8]` (1 ulp; the
  firmware's float evaluation order is not exactly reproduced).
- InitData rebuilt with macOS's pointers: 0 of 0xc8 bytes differ.

Note: the "alternating signs" in `rel_max_powers`/`rel_boost_freqs` noted
in `docs/gpu/firmware-decode.md`, and in the saved `hwb-all.bin`, are an
artefact of `agx dump` (OCaml 63-bit ints: bit 63 of each printed u64 is a
copy of bit 62). The raw snapshot values are all positive. Byte 7 of the
head words at +0x108, +0x5e0, +0x5e8 is wrong in those dumps for the same
reason.

## Gaps that block a real boot

1. **RegionC**: undecoded (firmware reads u32s +0..+0xe1c;
   DrainDeviceControlRing uses it). 13.x had a large table of power/
   thermal constants here.
2. **InitData +0xa8/+0xb0/+0xb8/+0xc0 targets**: readers known
   (scheduler, device-control drain, perf-state code), layouts not.
   +0xb0's object holds pointers up to +0x4ad0.
3. **RegionA**: contents unknown (13.x: empty 0x4000).
4. **RegionB beyond +0x1c0**: auxiliary channels (event, firmware log,
   ktrace, stats?) in a new shape, then more pointers to +0x2f0; RegionB's
   size; what `hdr_ptr_08/10` (HwDataB+0xc880) point at.
5. **HwDataB leftovers**: `rel_max_powers` formula (constants from macOS);
   `hw_rings` (macOS sets ring 0 → slot 0 and ring 2 → slot 2 with GPU
   VAs `0x72018xxxxx` in context 0's low half: what backs them, and whether
   the firmware boots without them); `counter_ctl` page contents;
   `unk_27e0`; `timestamp_region_base` backing; head fields unnamed;
   meaning of io `flags` = 2; slots 0x08/0x11/0x14/0x1f names.
6. **Device control**: no 27.2 layout for `DC_Init`/idle-timestamp
   messages, so nothing after the 0x81 message is drivable yet.
7. **UAT/handoff**: m1n1's handoff lock and TTBR layout assumed unchanged;
   whether we may keep iBoot's L1 slot 1 (device registers) as is; the
   firmware's own private mappings (`rtkit-private-vm-region`).
8. **m1n1 versioning**: `m1n1.constructutils.Ver` has no 27.2/G16 entry;
   `agx27_boot.py` avoids `m1n1.fw.agx.initdata` and m1n1's `AGX` class
   (13.x structures) and uses only `UAT`, `AGXASC` and the proxy.
