# AGX firmware 27.2: static decode (docs/gpu/plan.md, phases 1–2)

Reading the firmware the J614s actually runs (see [facts.md](facts.md) for
how it was dumped) with our own tools, so the host↔firmware interface can
be written down as schemas instead of guessed from traces alone.

Tooling (uncommitted, `lib/fw/`): `image.ml` (segments at their coprocessor
addresses, strings, pointer recognition incl. PAC bits), `a64.ml` (ARM64
decoder, checked against `llvm-objdump` by `test/fw_check`: all 52,480
branch/address/load-store instructions in the dump match), `prog.ml`
(functions, blocks, jump tables, xrefs, names from the firmware's own
`__func__` strings), `cli.ml`:

```
nixos-m4pro fw build/agx/20261114-boot2 summary|funcs|func|strings|xref|leftover|disasm
```

`disasm` (added 2026-11-14) prints every function annotated — grep it.

## State of the decode

- 1,060 functions cover 84.6% of `__TEXT` (86,608/102,400 words); padding
  (zero/udf) is 11.6%. 770 code-looking words in 62 ranges are unreached;
  they are exception-vector slots (`mrs s3_0_c5_c2_0` = ESR_EL1 at
  0x80/0x100/0x180…) and nop fields. Nothing large is missing.
- 50 jump tables recovered. **49 functions named** (see below).
- The firmware is stripped: no symbol table. Names come only from
  `__func__` strings that assert/panic macros bake in.
- `__DATA` in the dump is the *initialized* image, not runtime state: it is
  identical across boots and runtime pointer slots (e.g. the ctx global
  below) are zero. Live values must come from traces/proxy reads; the
  static decode gives the shapes.

## Naming

2026-11-14: only 29/1,060 functions were named. Three causes, measured:

1. The pool is small. Of 391 "strings", most are junk from decoding data
   as text. ~133 are identifier-like, of which ~80 are
   `kAGFIPIORegionType*` enum names and ~12 `AGX_CR_*` register names.
   Roughly **50 genuine `__func__` strings** exist.
2. The old rule named a function only if it *exclusively* used a name.
   89 functions reference identifier strings; 60 referenced only names
   shared with other functions (static-inline functions' asserts spread
   one `__func__` string over many callers) and got nothing. Fixed in
   `prog.ml`: shared names are taken too, marked `name~`. **49 named now**.
3. `fn_7ce4` ("AGFACRELeaveCriticalSection~", 4,833 instructions) is a
   megafunction that swallowed many inlined CRE paths; its name is
   misleading. Same for other `~` names that reference many strings.

## The InitData install path (fn_32224) — entry point to everything

Verified in the disassembly (`fw … func 32224`):

- Waits for message type **0x81 on endpoint 0x20** (matches what tracing
  saw), then sign-extends the message's pointer by
  `orr x8, x8, #0xfffff00000000000`.
- Refuses to run unless the first u64 of InitData equals
  **`0x0c8b6339839804c0`** (built with `movk` at 0x32278). On mismatch it
  logs *"Host and FW Interface is mismatched, please ensure the versions
  are aligned."* This constant is the **interface-version fingerprint** of
  27.2; a future firmware check is `InitData[0] == this value`.
- Checks **InitData+0x2c != 0** (u32 at 0x322d4, `cbz` → 0x32ab0, which
  logs *"Host-mapped FW allocations are disabled, but FW only supports
  enabled…"*). So +0x2c is 13.x's `host_mapped_fw_allocations` (moved from
  +0xa8) and must be 1; the snapshot has 1.
- InitData+0 is 13.x's `ver_info` (4×u16); the u64 compare above is the
  whole of it.
- Copies **0xc8 bytes** of InitData to the global block at
  `0x11e9f0..0x11eab8`, then caches these InitData pointers into globals
  (the loads go through `x9 = 0x11ea08` = copy+0x18, so `[x9, #0x90]` is
  InitData+0xa8):

| InitData offset | 13.x name | global | notes |
|---|---|---|---|
| +0x18 | regionB | `0x11e9e8` | **the ctx**: read by ~60 HAL functions, written nowhere else |
| +0x20 | regionC | `0x126130` | |
| +0xa8 | (new) | `0x11e918` | |
| +0xb0 | (new) | `0x11f398` | |
| +0xb8 | (new) | `0x126138` | |
| +0xc0 | (new) | `0x11e8f0` | |

  The four pointers at +0xa8..+0xc7 are the ones `lib/agx/initdata.ml`
  already has (from snapshot values); the firmware's reads confirm them.

- **The ctx is RegionB** (with `ver_info` at +0, 13.x's order puts regionA
  at +0x8, regionB at +0x18, regionC at +0x20; the trace decode also found
  RegionB at +0x18). `RegionB+0`, which `lib/agx/regionb.ml` called
  `hdr_ring`, is a **pointer to a large data structure** (read up to
  +0x27f4): call it HwDataX until it is matched to 13.x's HwDataA/B.
- From `RegionB[0]` (HwDataX, ≥ 0x27f4 bytes; 13.x HwDataB was
  0xb80) the boot path copies u32 fields into more globals
  (`0x1202a8…`, `0x120610…`, `0x1210f0…`): a qword at +0xfb0; u32s at
  +0xfc0, +0xfc4, +0xfc8, +0xfcc, +0xfd0, +0xfd4, +0xfdc, +0xfe0, +0xfe4,
  +0xfec, +0xff0, +0xff4, +0xff8, +0xffc, +0x1010, +0x1018, +0x101c,
  +0x1024, +0x1028, +0x102c, +0x1030, +0x1034, +0x1038, +0x103c, +0x1064,
  +0x1074, +0x109c, +0x10a4; a pointer at +0x10a8; u32s at +0x272c,
  +0x2730, +0x273c, +0x27e8, +0x27ec, +0x27f0. These are the fields to
  name next against the 13.x HwDataB tail and our snapshot.

## The IO-region machinery

The GPU's MMIO windows as the firmware names them (the fw side of what
13.x calls `AGXHWDataB.io_mappings`).

**Static name table**, image offset `0x8bba0..0x8bf00` (in `__DATA`), 54 entries × 16 bytes:
`{u32 name → TEXT const string, u32 0x200000, u32 region_id, u32 0}`.
The strings are suffix-merged: an entry points 0x12 past the string start
(`kAGFIPIORegionType` = 18 chars), which is why code xrefs looked empty.
53 entries are named; id `0x1f`'s name pointer goes to a runtime-filled
`__DATA` slot (0x94570). Ids run 0x00..0x3b; ids 0x08, 0x11, 0x15, 0x32,
0x33, 0x34 have no entry here (unknown regions or named at runtime).

| id | name | id | name | id | name |
|---|---|---|---|---|---|
| 0x00 | MCacheRegisters | 0x17 | DVFMMgpuRegisters | 0x2e | GFXCLKGENMGPU |
| 0x01 | FenderRegsHWL | 0x18 | AONPTDSpace | 0x2f | ThrtlStatCntrsCSRegisters |
| 0x02 | TempSensorRegister | 0x19 | PMCRegisters | 0x30 | AVMRControllerFastRegisters |
| 0x03 | MTRPMSRegisters | 0x1a | CSRIFPerf | 0x31 | FenderRegsAFRNIA |
| 0x04 | GPCAICSWInt | 0x1b | GPUCTLRIFPerf | 0x35 | DVFMAFRRegisters |
| 0x05 | AICBankedRegisters | 0x1d | HAT | 0x36 | DpwrMXURegisters |
| 0x06 | PMGRScratch | 0x1e | DPEPRegisters | 0x37 | PmgrMiscDie0 |
| 0x07 | SpecialAgentIdleDie0 | 0x1f | *(runtime name)* | 0x38 | AFRDCPMS |
| 0x09 | SpecialAgentIdleDie1 | 0x20 | FenderRegsGFenderCfg | 0x39 | PmgrMiscDie1 |
| 0x0a | PushTelemetryDashboardConfigSpace | 0x21 | GMGIFAFRegisters | 0x3a | ThrtlStatCntrsRegisters |
| 0x0b | PushTelemetryDashboard | 0x22 | CRERegisters | 0x3b | AFRRegisters |
| 0x0c | GFXCAXI2AFRegisters | 0x23 | FenderRegsGCPMS | 0x2a | FenderRegsDFenderPowerTransG16G |
| 0x0d | ANE0Registers | 0x24 | FenderRegsKSMFE | 0x2b | FenderRegsDFenderCSCfg |
| 0x0e | MTRRegisters | 0x25 | FenderRegsMCW | 0x29 | FenderRegsDFenderMGPUCfg |
| 0x0f | ANE1Registers | 0x26 | FenderRegsScratchRam | 0x2c | PMPDoorbell |
| 0x10 | GTIRegisters | 0x27 | FenderRegsBumper | 0x2d | FenderRegsIVDM |
| 0x12 | PushTelemetryDashboardReadSpace | 0x28 | FenderRegsPRC | 0x13/0x14 | AFRClkGenRegisters(1) |
| 0x16 | AFRD2DNIRegisters | 0x1f | *(runtime)* | 0x11/0x15/0x32-0x34 | *(no entry)* |

**Live state** (fn_35d7c, a telemetry/crashlog walker):

- `HwDataX+0x640` (`RegionB[0]+0x640`): per-region entries indexed by
  region id (8-byte entries tested for nonzero, then a double read at
  +0x10 of a per-region record: inline records rather than pointers;
  unconfirmed). fn_35d7c walks the 53 table entries, and for each
  live region copies 0x28 bytes of its state into `0x11f948+`. So a region
  struct is ≥ 0x24 bytes.
- fn_35d7c also reads `HwDataX+0xfa0` — more of the same field area the
  boot path copies.

**Firmware-internal registry** (fn_38098, region registration/dispatch),
all in static `__DATA` around image offset `0xd60a0`:

- `0xd62a8` (base+0x208): region **objects by id** (`str x25, [x10, id,
  lsl #3]`). Each object: +0x00 = **PAC-signed handler function**
  (`fn_1e730` or `fn_1f8f4`, picked by `*(u32*)HwDataX? == 3`), +0x08/+0x10
  data, +0x18 and +0x24 the region id.
- `0xd66d0`/`0xd66e0` (base+0x630/+0x640): parallel qword **flag arrays
  by id** (read-modify-write with `orr`/`bic`).
- The id for each object comes from `RegionB+0x79c`-style fields
  (partially traced; fn_38098 is the next function to decode).

## HwDataB (RegionB+0): identified (2026-11-14, later pass)

"HwDataX" is **13.x's HwDataB**, moved from RegionB+0x1a0 to RegionB+0
and grown. Checked field by field against m1n1's `AGXHWDataB` (13.5 offsets
computed from `fw/agx/initdata.py`) and against the boot5 macOS snapshot
(`agx decode … HwDataB27 <RegionB[0]>`); schema in `lib/agx/hwdata.ml`.

- **`io_mappings` at +0x640, as in 13.x.** 27.2 has **60 entries of 0x28
  bytes, indexed by the `kAGFIPIORegionType` id** (13.5: 0x19 of 0x20, in
  13.x's own order). So the "per-region entries" above and the region name
  table are the same thing: the firmware's names for the host's
  io_mappings slots. 0x28-byte entries also explain fn_35d7c's 0x28-byte copy.
- Entry: `phys u64, virt u64, size u32, range_size u32, sgx_offset u64,
  flags u32, pad`. `sgx_offset` is `phys - 0x288000000` for blocks inside
  the GPU's register space, else 0 (13.x: `readwrite`). `flags` is 0 or 2
  and is 2 on some empty slots too, so it is not "in use".
- 25 slots are live under macOS. **Slot 0x11** (no name in the table) is
  phys `0x288000000` size 0x21400: the GPU register block (ADT `sgx`
  reg 0). Slot 0x14: phys `0x28b000000`, 1 MiB.
- **The busiest firmware global, `0x11fbf8`, is `io_mappings[0x11].virt`**:
  fn_32224 copies HwDataB+0x8e8..+0x90b (that entry) into `0x11fbf0..` at
  boot, and `0x11d390` gets the same virt. The HAL's `[base + off]`
  accesses are GPU register accesses. In fn_38098 the 64-bit constants
  (`0x0028000000010190`, `0x00280000000014e0`) are **values written to
  registers** at `base + table[i] | 0x4000` (table: u32s at image 0x5d434,
  indexed by fn_35e20's result, < 7), not addresses.
- After the table (13.x +0x960 → 27.2 +0xfa0): `sgx_sram_ptr` +0xfa0;
  new u64 +0xfa8 (0x8000, likely the SRAM size); `chip_id` +0xfb0
  (0x6040); 14 u32 following 13.x's `unk_454..unk_48c` pattern with one
  dropped (`1 1 0 1 1 0 0 0 0 1 1 0 1 0`); `base_clock_khz` +0xfec
  (24000); new u32 +0xff0 (1); `power_sample_period` +0xff4 (8). The boot
  copy list (+0xfb0…) is therefore these fields and the 13.x ones after
  them; name the rest by continuing the walk past +0xff8.

**The rest of HwDataB (+0xff8..+0x2850)**, decoded by four parallel
passes over the snapshot, the ADT and the firmware's reads; the full layout
is `lib/agx/hwdata.ml` (`HwDataB27`, 0x2850 bytes; `agx decode` reads it
back from the boot5 snapshot, tests pin the anchors):

- +0xff8..+0x10a4: 13.5's `pad_498`..`num_frags` at +0x648. Two former
  paddings are fields (fn_32224 copies +0xff8, +0x1010). Then 12 inserted
  bytes: a u64 at +0x10a8 = 15 (the ADT's perf-state count) and zeros where
  13.x had `unk_540..unk_554` and `gpu_region_base` (unread by the
  firmware). `gpu_core` 19 (G16), `gpu_rev` 4, `num_cores` 20 at +0x10d4.
- **DVFS**: `max_pstate` 10 at +0x10e0; `frequencies[16]`,
  `voltages[16][16]`, `voltages_sram[16][16]` (13.x had 8 columns).
  11 live pstates. Columns 0/1 are the ADT's two perf tables (per die);
  the firmware only reads those two.
- **Two curves**: the ADT now has 16 perf states with two frequencies per
  voltage step above 765 mV. `pstate_map[2][16]` at +0x1ae4 (13.x
  `unk_arr_0`) picks 11 of them twice: main = 0,1,2,3,4,6,8,10,12,14,15
  (higher clocks) and alt = 0,1,2,3,4,6,7,9,11,13,15 (lower clocks:
  1062, 1182, 1242, 1326). The alt curve's frequencies are at +0x1924
  (13.x `unk_9f4_0`) and as a whole second table at +0x1df4..+0x263c
  (`max_pstate_alt`, frequencies, voltages, voltages_sram). What selects
  it is open.
- `unk_9b4` 1.02 (+0x1964); `rel_max_powers` and `rel_boost_freqs` are
  **f32** now (+0x19e4, +0x1a24; boost = (f − f[1])/(f[max] − f[1])·100,
  unrounded; all positive: an earlier "alternating signs" reading was a
  bug in `agx dump`, which copied bit 62 into bit 63 of printed u64s;
  fixed).
- +0x1b64: 0x148 zero bytes, the size of the AFR block: probably the CS
  table, left empty by macOS. AFR at +0x1cac: limit 7, `afr_max_pstate`
  7, `afr_frequencies[16]` 24..1470, `afr_voltages[16][2]`,
  `afr_voltages_sram[16][2]` (13.x: 8 entries);
  `agfReadPmpAFRPerfStateRequest` uses it.
- Tail: 13.x `unk_ae4` at +0x2664 and `unk_b38` (six all-ones u64) at
  +0x26d8 anchor it; 13.x's zero blob `unk_b6c` became real fields. Named
  from the firmware's use: `gl2_poll_timeout` +0x26d4, `gin1114_swwa` 2
  (+0x2710, "GIN-1114: AGFGIN1114Init(swwa=%u)"), `kick_defer_enable` 1
  (+0x2718), `sched_pause_timeout_us` 150 (+0x271c, "Unexpected scheduling
  pause timeout"), `power_hook_disable` (+0x2728), `trace_enable`
  (+0x2730), `hw_rings[4]` at +0x2740 (0x20 each: GPU VA, firmware VA,
  size 0x800, entry 0x40, hardware slot, firmware state; programmed into
  GPU registers 0x21148 + slot·8 as `base | size << 48 | 1`; slots 0 and 2
  set under macOS), `counter_ctl` +0x27d8 (GPU VA of a host page of
  counter thresholds), `hrb_mode` +0x283e (2-byte aligned; 3 = alternate
  HRB kick/completion path; 0 under macOS), `unk_2846` (1: sets GPU
  register bits at 0xbc08/0xbc00).

So what we must build matches 13.x's model: a HwDataB whose io_mappings
map these physical blocks into the GPU kernel address space, with the
firmware's slot numbering. The phys/size list above is the M4 Pro's.

## fn_38098 (first pass)

A pending-work dispatcher rather than region registration: it
takes bits from a pending mask (`0x11ebb8`; bit 4 → a second mask
`0x11ebe8`, lowest set bit = index), and per index:
- reads a host object pointer from the GPU register window (`[base+0xc0f0]
  & ~1`, plus `[base+0xc0f8]`), writes the index to `base+0x10398`;
- maintains it (fn_40270 with sizes 0x9a0 and 0x90: the object and the
  object at its +0x20; fn_40270 tail-calls cache/range helpers);
- fills a 0x38-byte record in the static array at image `0x71970` (record
  index from `[[obj+0x20]+0xc]`): +0 a PAC-signed handler (`fn_1e730` or
  `fn_1f8f4`, chosen by `HwDataB+0x283e == 3`), +8 the object, +0x10 the
  second pointer, +0x18 `obj+0x79c`, +0x24 the index, +0x28 `obj+0x7b0`,
  +0x2c 1, +0x30 3 or 0 by `[obj+0x20]+0x8c`;
- registers the record by `obj+0x79c` in `0xd62a8[]` and sets bits in the
  `0xd66d0`/`0xd66e0` masks.
What the 0x9a0-byte object is (a context or queue description?) is open.

## The four new InitData pointers (first pass)

Values in the boot5 snapshot and who reads the globals:

| InitData | global | readers | fields read near the load |
|---|---|---|---|
| +0xa8 → `…2f180` | `0x11e918` | `agx_scheduler`, `AGFHALMCWWaitForIdle~`, fn_38a84 | writes at +0xc..+0x1c |
| +0xb0 → `…20340` | `0x11f398` | `AGFAcceleratorDrainDeviceControlRing` (10), 15 HAL/scheduler fns | +0, +8, +0xf5, +0x930, pointers at +0x4058..+0x4ad0 |
| +0xb8 → `…2ea80` | `0x126138` | fn_2ff18 (34), perf-state code | u32s +0x8..+0x6a4 |
| +0xc0 → `…e3440` | `0x11e8f0` | no direct reads | (zero in the snapshot) |
| +0x20 regionC | `0x126130` | DrainDeviceControlRing, fn_30ac, fn_12260… | many u32 +0..+0xe1c |

None matches a 13.x RegionB pointer target (stats, hwdata_a, fault_info)
by its first bytes; naming them is open.

## Everything InitData points to (parallel decode, 2026-11-14)

Ten agents, each on one structure, from the firmware's reads plus all
macOS snapshots. Schemas: `lib/agx/regions27.ml`, `hwdata.ml`,
`regionb.ml`, `cmdqueue.ml` (sizes and anchors pinned by tests). Helper
scripts and full field tables stayed in the session scratchpad; the
results are summarised here.

| InitData | What it is | Size | Host must |
|---|---|---|---|
| +0x00 | `ver_info` = 0x0c8b6339839804c0 | 8 | write it |
| +0x08 RegionA | register writes run at every power-up (0x18-byte {value, reg, shift, kind}; kind 0 ends) | 0x4000 | zeroed page (empty list); pointer must be valid |
| +0x18 RegionB | header (HwDataB at +0), 13 queue channels, then Event/FWLog/KTrace/Stats {state, ring}, FWLog buffer and counters, five packed pointers | 0x27c | lay out exactly; `+0x26c` → a power object |
| +0x20 RegionC | packed host settings (power/perf tunables, timeouts, idle delays, override tables); copied by fn_30ac at boot and on a device-control command | ~0xe59 | ~50 macOS values (verbatim to start) |
| +0x2c | `host_mapped_fw_allocations` | u32 | 1 |
| +0xa8 FwStatus27 | replaces 13.x FWStatus: booted/ready/awake/recovery flags, wake counter, then the Event (0x40), FWLog (9 × 0x30), KTrace, Stats channel states; rings packed after it | 0x2c0 | zero; allocate the rings (Event 256×0x48, FWLog 9×256×0x48 + 9×256×0xd8 messages, KTrace 512×0x48, Stats 256×0x48) |
| +0xb0 KickState27 | firmware-owned device-control/stamp-log/idle state | 0xe740 | +0x4 = 1, +0xe714 = 1, +0x4ac0/+0x4ac8 → a 0x80-byte buffer; answer the idle handshake at +0x4ae0 (fw 1 → host 2, fw 3 → host 0) |
| +0xb8 PowerMgmt27 | 13.x RegionC's power block, moved: groups with "apply" flags (avg power, thermal, PPM 56768 mW), status from +0x544 | 0x700 | the listed constants; only the sample period derives from the ADT |
| +0xc0 | never read by the firmware; zero under macOS (maybe 13.x FWCtl) | ≤ 0x4bc0 | allocate |

HwDataB head (+0..+0x640) is 13.5's layout; the firmware reads only
`timestamp_region_base` (+0x28), the base of a 64 MiB window: completion
timestamps are written only through command pointers inside it.

**Submission (27.2).** CommandQueueInfo 0x80 (pointers, rb of 0x500 u64
command pointers, job list, event_id −1, process id, gpu_context);
CommandQueuePointers has `rb_size` at **+0x60** (13.x +0x50) and a new
replay index at +0x50. The 19-type dispatcher keeps 13.x's TA (0x9a0), 3D
(0x2240), blit, compute (0x1040) and barriers, but the traced queues carry
only type **0xf** (kick an entry of a per-DM hardware kick queue of 256 ×
0x200-byte entries) and **0x10** (clear the host's parent bit 0xfe on the
next entry): the work travels in the kick entries, whose layout beyond
+0x18/+0x30/+0x128/+0x148 is open. RunCmdQueueMsg27: queue +8, DM +0x10,
new write index u16 +0x14, queue slot u8 +0x16, new_queue +0x17.

**Messages.** Host → firmware: ep 0x20 0x81 (InitData); ep 0x21 0x83
kicks ((queue<<2)|kind, then 0x10), 0x84|0x11 device-control doorbell,
0x85 halt, 0x86 power ack (must match KickState+0x4ad0), 0x87|0x10 before
kick bursts. Device control ring: 256 × 0x40, types 0x4..0x3b; macOS
sends **0x15 Init** first, then 0x22 (idle timestamp), 0x2e, 0x20 (grow
acknowledgement), 0x13 (destroy context). Firmware → host: only **0x42**
("poll your rings"); Event entries 0x48 bytes: 1 completion (firing
masks), 0xd grow request (answer with DevCtrl 0x20), 4 timeout, 6/7/0xa/0xc
partly known. FWLog: index entry → 0xd8 message (13.x FWLogMsg), enable
at RegionB+0x250 (0 under macOS).

**Drafts from the same run:** `tools/agx27/` (phase 3: boot sequence,
Python layouts, an ADT → HwDataB builder: 3 bytes differ from macOS's
HwDataB with macOS's addresses, all explained; a boot script gated
behind `--i-know-this-writes-to-the-gpu`, not run), `docs/gpu/dt/`
(phase 4: GPU node draft; m1n1 kboot lacks T6040/G16 and 27.2),
`docs/gpu/survey/` (phases 5–6: aurora-silicon's fork already has
M4 Pro on 26.6.2 firmware with an interface hash one step from ours and
matching structures; Mesa G16 work exists only there).

## Open questions / next

- What `0x200000` in the name-table entries means (every entry has it):
  size class, mapping flags, or stride — find the consumer of the table's
  second column.
- fn_38098: what the 0x9a0-byte object is (MMIO bases are answered: the
  host's io_mappings).
- HwDataB open points: what selects the alt DVFS curve; a formula for
  rel_max_powers; whether +0x1b64 is the CS table.
- `agx decode` prints 64-bit fields with the top bit lost (Schema keeps
  them as OCaml ints); fix with Int64 for U64/Ptr.
- Name the four InitData pointers (+0xa8..+0xc0) and RegionC, starting
  from the fields read above.
- What iBoot rewrites in `__TEXT` per boot (facts.md): bound it by finding
  self-referential words.
- The interrupted data-flow pass (follow every InitData pointer through
  all functions) is now half-automated: the annotated `disasm` dump plus
  the globals above cover its first two levels by hand.
