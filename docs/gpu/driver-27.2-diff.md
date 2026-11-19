# Aurora's T6040 driver (25G83) vs. firmware 27.2: structure by structure

The map for adding a `V27_2` firmware variant to aurora's G17 driver
(nixos-aurora `drivers/gpu/drm/asahi`, the M4 Pro path). That driver
implements the macOS 26.6.2 firmware (25G83, interface
`0x0c8aa322039604c0`); the J614s runs the macOS 27.2 firmware (interface
`0x0c8b6339839804c0`). Companion to [firmware-decode.md](firmware-decode.md),
[facts.md](facts.md) and [survey/README.md](survey/README.md).

## Sources and conventions

- **Driver**: paths are relative to `drivers/gpu/drm/asahi/` (copy read
  2026-11-15). `fw/X.rs` means `g17/fw/X.rs` (e.g. `fw/initdata.rs`,
  `fw/variant.rs`); `fw/v25g83.rs` means `g17/fw/initdata/v25g83.rs` (the
  layouts); `init/v25g83.rs` means `g17/initdata/v25g83.rs` (the builder). The driver
  names structures after its own model (Root, MainConfig, bundle, private
  cluster, status A/B); the 13.x/m1n1 names our decode uses are given next
  to them.
- **27.2 decode**: `lib/agx/*.ml`, `docs/gpu/firmware-decode.md`,
  `tools/agx27/`.
- **Snapshot**: macOS 27.2's live objects, `build/agx/traces/27.2-boot5/`
  (`03-after-5000-msgs` unless stated; `01-first-app-tx-ep0x20` is the
  state when macOS sent the 0x81 InitData message). Many verdicts below
  come from reading the snapshot at the driver's offsets for this doc
  (scratch scripts, not committed). They are marked **(snapshot)**.
- **Verdicts**: *same*; *shifted* (by how much, from where); *restructured*;
  *unknown*. **Inferred** marks conclusions from values or position alone
  (no firmware read or code path confirms them).
- 27.2 macOS kernel VAs are written `K+off`, with `K = 0xfffffc2000000000`.
  The driver's fixed kernel-window offsets use the same base (`hw/t8140.rs`
  `kernel_window`, e.g. `PRIVATE_CLUSTER = 0x2_0000`).

## Summary

The 27.2 interface is the 25G83 interface one revision on. The object
graph is the same: the same root, the same channel table, the same rings,
the same kick records. Most changes are local:

- **Same**: the root (InitData) apart from the version word, the UAT
  description, the channel table and its rings, the event/log/trace/stats
  status area, work-ring slots, kick entries, the QueueConfig and
  KickPredecessor commands, the opening-record staging, and the init
  acknowledgement (status A `+0x14`).
- **Shifted**: HwData (register map 53 → 60 slots, then +0x120/+0x11c/
  +0x120/+0x128 runs), RegionC (+4 from `0x34`/`0x38`), PowerConfig
  (piecewise +0x10…+0x48), status B's recovery block (+0x1e0), MainConfig's
  `power_config_va` (+0x10), the bundle's work rings and MainConfig (+0x380).
- **Restructured**: the queue record (0xc0 → 0x80 bytes, qid-indexed at a
  0x80 stride), the private cluster (27.2 returns to the A18 Pro placement of
  status B and the power state), the bundle views (embedded in the bundle
  again), the firmware's crash-log segment (a third segment,
  `__DATA_SHARED_RO`).
- **Changed rules**: queue pointer layout (producer `+0x40`, recovery
  target `+0x50`, as 26A428), QID floor (macOS uses QIDs 0–6, so the floor
  is probably 0), opening-record opcode `0x15` (25G83: `0x16`).

---

## 1. Firmware image and segments

| | 25G83 (driver) | 27.2 (decode) | Verdict |
|---|---|---|---|
| Segments | TEXT 0x60000, DATA 0x138000 (`hw/t6040.rs:68-111`, `Build.images[].text_size/data_size`) | `__TEXT` 0x64000 at `0x7ffffc0000000000`, `__DATA` 0xc4000 at `+0x64000`, `__DATA_SHARED_RO` 0x8000 at `+0x128000` (phys `gfx-data-shared-ro`) (facts.md "Firmware") | **restructured**: three segments |
| Identity | SHA-256 of TEXT with the GKTS/ECAP entropy records' 8 bytes zeroed, plus TEXT/DATA sizes (`fwid.rs:1-30`, `g17/mod.rs:1886` `identify_image`: `fw-text` region, size of `fw-data`) | TEXT differs per boot, DATA and SHARED_RO do not (facts.md) | same method. The per-boot TEXT change is probably the entropy records the driver already masks (**inferred**; check by locating `GKTS`/`ECAP` in our two dumps) |
| Crash log buffer | `CrashBuffers::FirmwareData` (`hw/t6040.rs` CONFIG): the firmware requests a buffer inside its data segment; `g17/data_segment.rs:35-45` rejects any address outside the `fw-data` reserved region | the firmware's ep 1 buffer request is `0x10810001d90000`: 8 pages at phys `0x10001d90000`, the start of `__DATA_SHARED_RO` (snapshot `events.jsonl`) | **restructured**: the buffer is in the third segment, so `DataSegmentLog::map` would fail with EINVAL |
| Host log buffer | `MSG_LOG_BUFFER` (`0x9 << 52`, `g17/mod.rs:304`) exists; its only caller is `g17/mod.rs:2109` (check whether the 25G83 path reaches it) | macOS 27.2 sends `0x908c20c0838000` on ep 1: 8 pages at `K+0xc0838000` (`events.jsonl`) | same message; 27.2 macOS sends it |
| Kernel-half mapping | `FirmwareProfile::PublishedRoots`: the firmware publishes its root entries, which the driver confirms (`mmu.rs:4037` `confirm_firmware_root_entries`) | L1 slot 0 = firmware, 1 = device registers, 2 = host objects (facts.md) | same model (**inferred**; the third segment's mapping is the firmware's own) |

## 2. InitData root (`Root` + `SecondaryRoot::merged`)

Driver: `fw/initdata.rs:131-166` (Root, 0xb8), `:201-240` (SecondaryRoot
0xc8, `merged`), filled in `init/v25g83.rs:227-239`. 27.2:
`lib/agx/initdata.ml`; firmware copies exactly 0xc8 bytes (fn_32224).

| Off | Driver (25G83) | 27.2 | Verdict |
|---|---|---|---|
| +0x00 | `version` = `[0x04c0, 0x0396, 0xa322, 0x0c8a]` (`fw/initdata.rs:33`) | `0x0c8b6339839804c0` = `[0x04c0, 0x8398, 0x6339, 0x0c8b]` | **changed**: three of four u16 differ (the survey's "only the high half-word" is wrong) |
| +0x08 | `region_a_va` | RegionA | same |
| +0x10 | `unk_10` = 0 | `unk_8`/`unk_c` = 0 | same |
| +0x18 | `main_config_va` | RegionB (= MainConfig, §4) | same |
| +0x20 | `region_c_va` | RegionC | same |
| +0x28 | `role` = 0 (Primary) | `unk_28` = 0 | same |
| +0x2c | `unk_2c` = 1 | `host_mapped_fw_allocations` = 1 (firmware refuses 0) | same |
| +0x30..+0x94 | page size/bits/levels, `level[3]` (0x20 each, `LevelDescriptor::new`) | identical bytes (snapshot; `tools/agx27` rebuilt it with 0 differences) | same |
| +0x94 | `unk_94[0x14]` | pad (named `pad_8c` in initdata.ml, which is a 13.x name; the offset is +0x94) | same |
| +0xa8 | `status_a_va` | FwStatus27 | same (§5) |
| +0xb0 | `status_b_va` | KickState27 | same pointer, contents shifted (§6) |
| +0xb8 | `power_state_va` | PowerMgmt27 | same pointer, object moved (§7) |
| +0xc0 | `config_va` (the configuration "its status follows at +0x80", `fw/v25g83.rs:48`) | "+0xc0, never read, zero" | same (status pointer confirmed: PowerConfig holds `config+0x80`, §9) |

Size 0xc8 in both. **Only the version word changes.**

## 3. Private cluster (where status A/B, the state grid and the config live)

Driver 25G83: `fw/v25g83.rs:40-51` (`private`), cluster at the fixed
`K+0x20000` (`hw/t8140.rs` `PRIVATE_CLUSTER`), grid at cluster+0
(`g17/initdata.rs:1767` `state_offset`). A18 (26A428) for comparison:
`fw/initdata.rs:1574-1595`. 27.2: snapshot pointers.

| Object | 26A428 | 25G83 (driver) | 27.2 (macOS VA → cluster offset) | Verdict vs 25G83 |
|---|---|---|---|---|
| State grid (13 ChannelStates) | +0 | +0 | `K+0x20000` → +0 | same |
| Status B | +0x340 | +0x10000 | `K+0x20340` → **+0x340** | **moved** (back to the A18 place, directly after the grid) |
| Power state | in status B at +0xe440 (+0xe780) | separate fixed object `K+0x170000`, 0x6a8 bytes (`fw/v25g83.rs:30`) | `K+0x2ea80` → **+0xea80** (status B + 0xe740) | **moved** into the cluster |
| Status A | +0xee40 | +0x1f180 | `K+0x2f180` → **+0xf180** | **moved** (−0x10000) |
| Config (`+0xc0`) | (secondary) | +0xd3440 | `K+0xe3440` → **+0xc3440** | **moved** (−0x10000) |
| MainConfig `unk_18` page | – | +0x8000 (`MAIN_HEADER`) | RegionB+0x18 = 0 | **dropped** (macOS writes 0) |
| Cluster size | 0x178000 | 0xd4000 | ≥ 0xc34c0 | 0xc4000 would mirror the −0x10000 (**inferred**) |

Whether the 27.2 firmware needs these exact offsets or only follows the
root's pointers is **unknown**. Copying macOS's placement is the safe
choice.

## 4. MainConfig (13.x/our RegionB) and its channel table

Driver: `fw/initdata.rs:476-536` (0x4c0 + device-control ring), filled in
`init/v25g83.rs:191-225`. 27.2: `lib/agx/regionb.ml` (decoded up to
+0x27c); the rest from the snapshot, RegionB at `K+0xc07be940` = bundle
+0x1e940.

| Off | Driver | 27.2 | Verdict |
|---|---|---|---|
| +0x00 | `hw_data_va` = bundle+0 | `hwdata_b` = bundle+0 | same |
| +0x08, +0x10 | `firmware_area_va[2]`: 25G83 = a separate page at `K+0x410000` (0x88 bytes), twice | both = bundle+0xc880 (snapshot) | **moved** into the bundle (0xc0 bytes before the first work ring) |
| +0x18 | `unk_18` = cluster+0x8000 (25G83 only) | 0 | **changed**: macOS writes 0 |
| +0x20..+0x1c0 | `channels[0..13]`: `ChannelEntry::ring` = {consumer, unk_10, producer, ring}; work channels at grid `work_slot(ch)*0x40`, rings at `WORK_RINGS + work_slot*0x1800`; control at grid+0x300, ring = MainConfig+0x4c0 (`fw/initdata.rs:273-353`) | `QueueChannels27` {read, +0x10, write; ring}: every pointer equals the driver formula with grid `K+0x20000` and `WORK_RINGS` = bundle+0xc940; DevCtrl ring = RegionB+0x4c0 (snapshot) | same layout (ring base moved, §8) |
| +0x1c0 | channel 13 = {status A+0x40, +0x2c0, +0x80, +0x4ac0} | event {state, ring}, fw_log {state, ring}: `K+0x2f1c0`, `+0x2f440`, `+0x2f200`, `+0x33c40` | same |
| +0x1e0 | channel 14 = {status A+0x240, +0xa6ac0, +0x280, +0xafac0} | ktrace, stats: `K+0x2f3c0`, `+0xd5c40`, `+0x2f400`, `+0xdec40` | same |
| +0x200 | channel 15 = {status A+0x2d2c0, 0, 0, 0} | `fw_log_buf` = `K+0x5c440` = status A+0x2d2c0 | same (regionb.ml's `fw_log_slots`/`fw_log_seq` at +0x208..+0x24f are the rest of channels 15/16, zero) |
| +0x250 | `log_enable` (0) | `fw_log_enable` (0) | same |
| +0x254 | `view_va[5]`: 25G83 = five separate pages `K+0x414000, 0x400000, 0x404000, 0x408000, 0x40c000` (`fw/v25g83.rs:32`) | bundle+0x2880, +0x34c0, +0x4540, +0xc000, +0xc080 (regionb.ml's `ptr_254..ptr_274`; `power_obj` at +0x26c is view 3) | **restructured**: in the bundle again, as on 26A428 (`bundle::VIEWS` = 0x2740, 0x3380, 0x4400, 0xbc80, 0xbd00; 27.2 = +0x140 ×3, +0x380 ×2) |
| +0x27c | `unk_27c[0x54]` = 0 | 0 | same |
| +0x2d0 | `zero_page_va` (bundle+0x40000) | bundle+0x40000 | same |
| +0x2d8..+0x2f0 | PB / page-pool descriptor tables, low alias and kernel VA | same four fields (`0x72_0183_8000`, `K+0x1550000`, `0x72_0184_0000`, `K+0x1558000`) | same layout (macOS low aliases are `0x72_…`, driver's `0x70_…`) |
| +0x300 | `unk_300` = 4 | 4 | same |
| +0x308, +0x30c | 0 | 4, 100 | **values**: macOS sets them (meaning **unknown**) |
| +0x320..+0x328 | 0 | 1, 2, 3 | **values**: macOS sets them (**unknown**) |
| +0x32c | `unk_32c` = 1 | 1 | same |
| +0x344 | `unk_344` = 0xabcdabcd | 0xabcdabcd | same |
| +0x3e0 | `unk_3e0` = 0xff | 0xff | same |
| +0x471 | `power_config_va` (bundle+0x5380, unaligned) | 0 at +0x471; **bundle+0x5380 at +0x481** | **shifted +0x10** |
| +0x4c0 | device-control ring, 256 × 0x40 | ring at RegionB+0x4c0 | same |

### Channel state (`ChannelState`, 0x40)

`fw/initdata.rs:303-331`: consumer +0, unk_10 +0x10, producer +0x20.
27.2: same three counters (`regionb.ml` `ChannelState`, `RX_PRODUCER_OFFSET`
0x20). **Same.** Grid order (engine × reversed priority) **same**.

### Opening record

Driver: `OpeningRecord` opcode 0x16 in DevCtrl slot 0, then control
state consumer 0, unk_10 0, producer 1 before the 0x81 message
(`fw/initdata.rs:420-445`, `init/v25g83.rs:220-255`). 27.2 snapshot 01 (at
the 0x81 message): DevCtrl slot 0 = **0x15**, grid+0x300/0x310/0x320 =
0/0/1. **Same mechanism, opcode 0x16 → 0x15.**

## 5. Status A (13.x FWStatus; our FwStatus27) and the init acknowledgement

Driver: `StatusBlock` (0x80; host sets +0x4 = 1) `fw/initdata.rs:1467-1490`;
status-area offsets `fw/initdata.rs:357-376`; init accepted when status A
+0x14 == 1 (`g17/initdata.rs:1816`, `InitAck::Status`,
`g17/mod.rs:2287-2289`). 27.2: `regions27.ml` `FwStatus27` (0x2c0) + rings.

| | Driver | 27.2 | Verdict |
|---|---|---|---|
| +0x04 | host 1 | `booted` = 1 | same |
| +0x10, +0x14 | firmware-owned; +0x14 = 1 is the ack | `awake`, `fw_ready` = 1 (snapshot 02/03: +0x14 = 1) | same |
| +0x40 / +0x80 / +0x240 / +0x280 | event / log (9 × 0x30) / trace / stats states | same offsets | same |
| rings | event +0x2c0 (256 × 0x48), log +0x4ac0, log messages +0x2d2c0, trace +0xa6ac0 (512 × 0x48), stats +0xafac0 | the same sizes give the same offsets (firmware-decode.md; snapshot pointers in §4) | same |
| ack message | `MSG_INITDATA_ACK` (0x09) not used with `InitAck::Status` | firmware → host traffic is only 0x42 | same |

Note: `regionb.ml`'s comment "fw_log 6 × 0x100 × 0x1b0" is stale; 9
sub-rings of 256 × 0x48 plus 9 × 256 × 0xd8 messages is what the addresses
show.

## 6. Status B (the driver's PrimaryStatusB; our KickState27)

Driver 25G83 writes only `StatusBlock::new()` at +0 and the fwctl
pointers at +0x48e0/+0x48e8 (`init/v25g83.rs:176-189`; "keeps the A18 Pro's
field offsets up to its recovery words"). Recovery uses
`PrimaryStatusB::RECOVERY_*` (`fw/initdata.rs:1510-1560`,
`g17/initdata.rs:1930-2090`). 27.2: `regions27.ml` `KickState27` (0xe740).

| Field (driver) | 25G83/26A428 off | 27.2 off | 27.2 evidence | Verdict |
|---|---|---|---|---|
| `status.unk_4` = 1 | +0x4 | +0x4 (`host_4`) | snapshot 1 | same |
| `recovery_info[256]` (8 bytes each) | +0x40b8 | +0x4298 (`stamp_log[256]`) | same size, +0x1e0 | **shifted +0x1e0** (**inferred** from size and position) |
| `recovery_slot_mask` | +0x48d8 | +0x4ab8 | inside our `idle_report` | **shifted +0x1e0** (**inferred**) |
| `fwctl_state_va`, `fwctl_ring_va` (= +0x40) | +0x48e0, +0x48e8 | +0x4ac0, +0x4ac8 | snapshot `K+0x100000`, `K+0x100040` | **shifted +0x1e0** |
| `recovery_epoch` | +0x48f0 | +0x4ad0 (`idle_seq`; DevCtrl +0x18 and mailbox 0x86 carry it) | firmware decode | **shifted +0x1e0** |
| `recovery_state` (fw 1/3, host 2/0) | +0x4900 | +0x4ae0 (`idle_handshake`, same protocol) | firmware decode | **shifted +0x1e0** |
| `host_recovery` | +0x4910 | +0x4af0 (`idle_handshake_arg`) | position | **shifted +0x1e0** (**inferred**) |
| `unk_e434` = 1 (A18; 25G83 driver leaves 0) | +0xe434 | +0xe714 (`host_e714` = 1), +0xe718 = 8 | snapshot | **shifted +0x2e0**; +0xe718 = 8 **new** |
| `power` (`PowerState`, 0x6c0) | +0xe440 (A18) | +0xe740 = InitData+0xb8 (§7) | snapshot | **shifted +0x300** |

The fwctl page: driver `FWCTL_SIZE` 0x4000 at `K+0x1c0000`, ring at +0x40;
macOS 27.2 uses `K+0x100000`. Same shape. Where the +0x1e0 between +0x80
and +0x40b8 comes from is **unknown** (KickState27 decodes ids at
+0x4020, slots/entries at +0x4060..+0x4070).

## 7. Power state (the driver's power-state object; our PowerMgmt27)

Driver 25G83: 0x6a8 bytes at `K+0x170000`, only +0xc8 = 10100 (fast-die
target, 0.01 °C) and +0xcc = 9600 (release) (`fw/v25g83.rs:30, 662-665`;
written in `init/v25g83.rs:240-245`). 27.2: `regions27.ml` `PowerMgmt27`
(0x700; firmware reads u32s +0x8..+0x6a4, i.e. exactly 0x6a8).

- **Same object**: +0xc8/+0xcc hold the same pair; macOS writes 11000/8000
  (`regions27.ml` calls +0xc8 `unk_8cc`; it is the target temperature).
- macOS also fills +0x10 (31), +0x14 (0.040465), +0x18 (0.8093), +0x1c
  (40), the zone/PPM groups and `sample_period_aic`. 25G83 keeps the same
  constants in PowerConfig (+0x29d8, +0x29e8, +0x29f4). **Values differ**:
  copy macOS's block.
- **Placement restructured**: inside the private cluster at status B +
  0xe740 (§3), not a separate page.

## 8. Bundle (HwData + PowerConfig + rings + MainConfig)

Driver: `fw/initdata.rs:383-410` (`bundle`, the A18 layout, shared by
25G83), `fw/v25g83.rs:54` (`POWER_CONFIG` 0x5380), bundle at `K+0xc0788000`.
27.2 bundle: `K+0xc07a0000` (HwDataB).

| Offset | 25G83 | 27.2 | Verdict |
|---|---|---|---|
| HwData | +0 (0x3db4 struct) | +0 (≤ 0x2880 before view 0) | §10 |
| Views | separate pages | +0x2880, +0x34c0, +0x4540, +0xc000, +0xc080 | restructured (§4) |
| PowerConfig | +0x5380 | +0x5380 | same place, contents shifted (§9) |
| Firmware area | separate page | +0xc880 (0xc0) | moved |
| Work rings | +0xc5c0, 12 × 0x1800 | +0xc940 | **shifted +0x380** |
| MainConfig + DevCtrl ring | +0x1e5c0 (+0x4c0) | +0x1e940 (+0x4c0) | **shifted +0x380** |
| Zero page | +0x40000 | +0x40000 | same |
| Completion rings (high alias) | +0x48000, +0x70000 | `K+0xc07e8000`, `K+0xc0810000` = +0x48000, +0x70000 | same |
| AON table | separate page `K+0xc0500000` | `K+0xc07c8000` = bundle+0x28000, right after a 0x28000 bundle | moved (**inferred** to be outside the bundle) |

## 9. PowerConfig (bundle+0x5380)

Driver: `PowerConfig25G83` 0x6510 bytes, ~160 nonzero words
(`fw/v25g83.rs:414-646`). **No 27.2 schema exists in lib/agx**; the rows
below compare each driver word with the snapshot, looking for a constant
shift (snapshot).

| 25G83 range | 27.2 | Notes |
|---|---|---|
| +0x000..+0x0bf | same offsets | values differ: +0x0 = 1 (driver 0), +0x4 = 199998 (driver 200000), +0x10 = 0 (4), +0x38 = 1 (0), +0x44 = 0xc (1); new +0x9c..+0xa8 = 1 and +0xac = 338.0 (f32) |
| +0x0c0..~+0x2870 | **+0x10** | 1.02 × 11 at +0xd0; max-power copies 0xa04/0xabc → 0xa14/0xacc; f32 0x9e0 → 0x9f0. Words 0x9ec, 0xa70, 0xa7c, 0xa84, 0xad0 not found at any shift |
| ~+0x28c0..+0x2c30 | **+0x28** | max-power copies 0x28c8..0x28d0 → 0x28f0..0x28f8, 0x2a08 → 0x2a30. Not found: 0x29bc, 0x29c8, 0x29d0, 0x2b94, 0x2be8; the f32 at 0x2a04 is not at 0x2a2c |
| +0x2e2c..+0x2f14 | **+0x20** | 8 bytes removed between 0x2c30 and 0x2e2c |
| +0x3b50..+0x5b64 | **+0x48** | `CONFIG_STATUS_POINTER` 0x3b50 → 0x3b98 holds `K+0xe34c0` = config+0x80 (confirms §2) |
| +0x6318..+0x6370 | **+0x28** | `AON_POINTER` 0x6318 → 0x6340; `g0TR`/`g1TR` 0x6320 → 0x6348; `r0TR` 0x6368 → 0x6390 |
| `ENTROPY` 0x63d4, 0x6420, `LEAKAGE_OFFSET` 0x642c (56 words) | **unknown** | everything after 0x6398 is zero under macOS except +0x63f0 = 1. The leakage words are not where +0x28 puts them (or macOS leaves them zero) |

Verdict: **shifted piecewise**. A V27_2 needs its own word list (start from
macOS's block). The insertion points inside each run are **inferred**.

## 10. HwData (13.x HwDataB; our HwDataB27)

Driver: `HwData25G83` 0x3db4 (`fw/v25g83.rs:113-399`). 27.2:
`lib/agx/hwdata.ml` `HwDataB27` 0x2850; values checked against the snapshot.

| 25G83 range | 27.2 offset | Verdict / notes |
|---|---|---|
| +0x000..+0x63f (`unk_0..unk_28`, `unk_30[0x610]`) | same | same values (0x6f_0000_0000, 0xffc0_0000, …); +0x28 = timestamp window (driver `0xffff_fc21_8140_0000`) |
| `register_map` +0x640, **53** × 0x28 (`REGISTER_MAP_SLOTS`, `fw/initdata.rs:599`) | +0x640, **60** × 0x28 | **grown**: entry layout same (`RegisterMapEntry` = phys, va, total, element, `unk_18` = sgx offset, `unk_20` = flags). Slots 0–22 keep their numbers; driver slots 26–43 are **+5** in 27.2 (26→0x1f, 28→0x21, 29→0x22, 31→0x24, 32→0x25, 33→0x26, 34→0x27, 35→0x28, 37→0x2a, 39→0x2c, 40→0x2d, 41→0x2e, 43→0x30; same phys/size/`unk_18`/flags, compared with `tools/agx27/build_initdata.py` `IO_MAPPINGS_T6040`). The 5 new ids lie in 0x17..0x1e (which ones: **unknown**); 2 more at the end. macOS sets flags = 2 on 17 empty slots; the driver has `reserved_slots: &[]` |
| `unk_e88[8]` (0) | +0xfa0 `sgx_sram_ptr` (a 0x8000 mapping of phys 0x288d60000), +0xfa8 = 0x8000 (**new** u64) | **changed**: macOS fills both |
| `chip_id` +0xe90 … `unk_eb8` | **+0x120** (`chip_id` +0xfb0) | same values |
| `unk_ebc` (0) | – | **dropped** (**inferred** from the 1/0 pattern) |
| `unk_ec0`..`unk_f8c` | **+0x11c** | base clock 0xed0 → 0xfec, power period 0xed8 → 0xff4, 0x1f at 0xf04 → 0x1020, 0x07002004 at 0xf24 → 0x1040. **Values**: 0xf28 → 0x1044 is **0xc** (driver 6); 0xf6c → 0x1088 is **1** (driver 0) |
| `unk_f88` active cores | +0x10a4 | macOS writes **20** on this 16-core unit |
| `unk_f8c` = 0xf | +0x10a8 | same (hwdata.ml types it u64) |
| `unk_fb8` = 0x1c | +0x10d4 `gpu_core` | **value**: macOS **0x13** |
| `unk_fbc` = 4, `unk_fc0` = active cores | +0x10d8, +0x10dc | 4 same; macOS writes **20** |
| `perf_a` (`PerfGroup` 0x704) + `unk_16c8[0x140]` | +0x10e0, 0x844 together | same shape (max, freq[16], mv[16][16], sram[16][16]; the driver's struct covers 11 SRAM rows plus padding) |
| `perf_b_freq_mhz` +0x1808, `unk_1848` 1.02 × 11 | +0x1924, +0x1964 | same |
| `perf_a_relative` +0x18c8, `perf_b_relative` +0x1908 (u32 "percent") | +0x19e4, +0x1a24 | **type**: 27.2 holds **f32** (e.g. 9.69, 17.2, … 100.0). Check what the loader's `relative_a/b` encode |
| `unk_1934[0x94]` | +0x1a50.. | 27.2 has f32 `unk_1a64[16]` here (zero in this snapshot) |
| `perf_a_states`, `perf_b_states` +0x19c8, +0x1a08 | +0x1ae4, +0x1b24 (`pstate_map[2]`) | same |
| `cs_perf` +0x1a48, `afr_perf` +0x1b90 (`AuxPerfTable` 0x148) | +0x1b64, +0x1cac | same layout; **value**: macOS leaves CS zero (the driver fills it unless `cs_perf_table` is false) |
| `perf_b` +0x1cd8 + `unk_23dc` | +0x1df4 | same (alt curve) |
| `unk_2544..2554` (5 6 3 7 7) | +0x2660 | +0x11c, same |
| `unk_2570` active cores | +0x268c | macOS **16** |
| `unk_2578`, `unk_2598/25a8` (0 1 1 1), `unk_25bc` (−1 × 12) | +0x2694, +0x26b4/+0x26c4, +0x26d8 | +0x11c, same |
| `unk_25f4` = 2, `unk_25fc` = 1 | +0x2710 (`gin1114_swwa`), +0x2718 (`kick_defer_enable`) | +0x11c, same |
| `unk_2600` (0) | +0x271c `sched_pause_timeout_us` | **value**: macOS 150 |
| `unk_2614` = 1, `unk_261c` = 0x100 | +0x2734, +0x273c | **+0x120**: one u32 inserted between 0x25fc and 0x2614 (where exactly: **unknown**; 27.2 +0x2730 `trace_enable` = 1 is either the new word or 25G83's 0x2610) |
| `completion_rings[4]` +0x2620 (`CompletionRingDescriptor`, `fw/initdata.rs:822`) | +0x2740 `hw_rings[4]` | +0x120, same: 0x800 entries × 0x40, indices 0 and 2 |
| `qos_va` +0x26b8 | +0x27d8 `counter_ctl` | +0x120, same field (`K+0x1548000`) |
| `unk_26c0`, `unk_26c4` = 1 | +0x27e8, +0x27ec | **+0x128**: new u64 GPU VA at +0x27e0 (`K+0x1540000`, 0x8000 below the QoS page; what it is: **unknown**) |
| `unk_26f4` = 1 | +0x281c | +0x128, same |
| `unk_26f8[0x16bc]` (0) | +0x2820..+0x284f | **values**: `hrb_mode` u16 +0x283e = 0, +0x2846 = 1, +0x284a = 1 under macOS |

Verdict: **shifted** in five runs; a new struct `HwData27_2`, ≤ 0x2880
bytes so that it does not overlap view 0.

## 11. RegionA

Driver: `RegionA`, 0x4000 zeroed (`fw/initdata.rs:1206`). 27.2: 0x4000
zero bytes (an empty register-write list, `hwdata.ml` `RegionAEntry27`).
**Same.**

## 12. RegionC

Driver: `RegionC` 0x1000 (`fw/initdata.rs:1262-1450`), T6040 values
`hw/t6040.rs:178-195`. 27.2: `regions27.ml` `RegionC27` (~0xe59).

| Driver field | 25G83 off | 27.2 off | macOS 27.2 value | Verdict |
|---|---|---|---|---|
| `context_switch_timer_mask` | 0x0 | 0x0 | – | same |
| `unk_24` = 3000 | 0x24 | 0x24 | 3000 | same |
| `idle_power_off` = 1 | 0x30 | 0x30 | 1 | same |
| `unk_34` = 1, `unk_38` = 0 | 0x34, 0x38 | 0x34 = 1, 0x38 = 1, 0x3c = 0 | | **one u32 inserted at 0x34 or 0x38** (which one: **unknown**) |
| `unk_3c` = 120 | 0x3c | 0x40 | 120 | +4 |
| `unk_54` u16 (T6040: 4000), `unk_56` 40, `unk_58` 0xffff | 0x54..0x58 | 0x58..0x5c | 4000, 40, 0xffff | +4 |
| `unk_5e/62/66` = 1, 1, 3 | 0x5e.. | 0x62.. | 1, 1, 3 | +4 |
| `context_switch_timer_multiplier` u8 | 0x6a | 0x6e | 1 | +4 |
| `unk_78[3]` (T6040: 1, 0, 0) | 0x78 | 0x7c | **1, 2, 902** | +4, values differ |
| `max_power_mw` | 0x84 | 0x88 | 56768 | +4 |
| `unk_88/8c/98` = 1000 | | +4 | 1000 | +4 |
| `effort`, `unk_e8` (live) | 0xe4, 0xe8 | 0xe8, 0xec | | +4 (**inferred**: no reader decoded) |
| `unk_7c4` (T6040: 1500), floats 0x7c8..0x7e4, 6/1/1/100/100 | 0x7c4.. | 0x7c8.. | 1500, 1.0 0.8 0.2 0.9 0.1 0.25 0.6 0.9, … | +4 |
| `unk_998/99c/9a0` = 40, 10, 250; `unk_9a4` = 1 | 0x998.. | 0x99c.. (`progress_check_interval`) | same | +4 |
| `unk_9b8` = 2, `idle_power_off_delay` 40, `unk_9c0` 5 | 0x9b8.. | 0x9bc.. | 2, 40, 5 | +4 |
| `unk_9c8` 40, `compute_watchdog` 50, `unk_9d0` 1 | 0x9c8.. | 0x9cc.. | 40, 50, 1 | +4 |
| `unk_9e0[8]` (T6040 table) | 0x9e0 | 0x9e4 | byte-identical table | +4 |
| `unk_e1d` = 1, `unk_e39` = 3, `unk_e3d` = 1 | | 0xe21, 0xe3d, 0xe41 | 1, 3, 1 | +4 |
| firmware-written words | 0xe41..0xe50 | 0xe45, 0xe49 | | +4 |
| `power_assert_tally` (live, unaligned) | 0xe51 | 0xe55 | 8 (consistent with a running count) | +4 (**inferred**) |

Verdict: **shifted +4** from 0x34/0x38 to the end. The live fields
(`effort`, `unk_e8`, `power_assert_tally`) move with the rest.

## 13. Queues: pointer block, queue record, work-ring slot

### Pointer block (`PointerBlock`, 0x80)

Driver: `g17/fw/queue.rs:131-155`; `ITEM_RING_ENTRIES` 0x500;
`PointerLayout` per variant (`fw/variant.rs:13`): 25G83 `producer 0x50,
recovery_target None` (`:150-154`), 26A428 `producer 0x40,
recovery_target Some(0x50)` (`:122-125`). 27.2: `cmdqueue.ml`
`CommandQueuePointers`; snapshot queues.

| Off | 27.2 (snapshot) | Verdict |
|---|---|---|
| +0x00 `done`, +0x30 `unk_30` | firmware cursors (+0x30 == +0x00 when idle) | same |
| +0x40 | host producer: qid 5's +0x40 = 0x30 while done = 0x2e | **changed** (25G83 has it at +0x50) |
| +0x50 | 0xffffffff on every queue (the replay path's write index, fn_17c44) | **changed**: this is 26A428's `recovery_target`, initialised to `u32::MAX` |
| +0x60 `entries` | 0x500 | same |

**27.2 = the V26A428 pointer layout.**

### Queue record (`QueueRecord` 0xc0; our CommandQueueInfo27 0x80)

Driver: `g17/fw/queue.rs:274-305`. 27.2: `cmdqueue.ml`; snapshot: macOS
keeps the records in one array at `K+0xc0000000`, **0x80 apart, indexed by
QID** (QID 0 at +0, QID 5 at +0x280).

| Driver | 25G83 off | 27.2 off | Verdict |
|---|---|---|---|
| `pointers_va`, `items_va`, `job_list_va` | 0, 8, 0x10 | 0, 8, 0x10 | same |
| `unk_18[0xc]` | 0x18 | 0x18 (0 or 0x30), 0x1c (firmware copy of done) | same span |
| `unk_24` = −1 | 0x24 | 0x24 = −1 | same |
| `priority[2]` | 0x28 | 0x28 (0,0 / 2,2) | same |
| `unk_30[6]`, `unk_36` = 0xffff | 0x30..0x37 | 0x30..0x37 (0xffff at 0x32 or 0x36, with −1 nearby) | same span, values vary (**unknown**) |
| `unk_38`, `unk_3c` | 0x38, 0x3c | 0x38 (1/0), 0x3c (1/2) | |
| `policy` | 0x40 | 0x3c? | **shifted −4** (**inferred**) |
| `unk_44` = −1 | 0x44 | 0x40 = −1 | **shifted −4** |
| `owner_pid` | 0x48 | 0x44 (`process_id`; also in each 0xf command at +0x5a) | **shifted −4** |
| `unk_4c[0x50]` | 0x4c | 0x48..0x6f (barrier count +0x54, counter +0x68) | restructured |
| `scheduler_va` | 0x9c | 0x70 (`K+0xc07d0000` / `+0x80`, per owner) | **moved** (**inferred**: a per-owner page in both) |
| size | 0xc0 | **0x80** | **restructured** |

### Work-ring slot (`WorkSlot`, 0x18; our RunCmdQueueMsg27)

Driver `g17/fw/channels.rs:537-553`: `unk_00`, `queue_va` +8,
`data_master` +0x10, `items_end` u16 +0x14, `qid` u8 +0x16, `first` +0x17.
27.2 `regionb.ml` `RunCmdQueueMsg27`: identical (`queue_slot` is the QID).
**Same.** (facts.md's early "a constant 1 … a constant 5" reading is
superseded by this.)

### QID floor

Driver 25G83: `qid_floor` 32, "QIDs below 32 belong to the firmware's
bootstrap protocol" (`fw/variant.rs:149-150`; `kick::queue_limit`). 27.2
snapshot: macOS's work rings name **QIDs 0, 1, 4, 5, 6**. **Changed**: the
floor is probably 0 (**inferred**; check that the 27.2 firmware reserves
no QIDs).

## 14. Commands and kick entries

Driver: `CommandTag` (`g17/fw/queue.rs:86-101`), `QueueConfig` (0xc0,
`:437-505`), `KickPredecessor` (0x12, `:658-671`), `KickAnnounce` (0x18,
`:608-626`), `InitBufferManager` (0x18, tag 5, `:576-589`), `KickEntry`
(0x200, `g17/fw/kick.rs:417-452`). 27.2: `cmdqueue.ml` (`KickCmd27`,
`KickRelease27`, `Barrier27`), firmware dispatcher (19 types).

| Driver | 27.2 | Verdict |
|---|---|---|
| `QueueConfig`, tag 0xf: kick ring VA +8, firmware alias +0x10, qid u16 +0x18, install +0x1a, priority +0x1e, data master +0x22, seed valid +0x26, seed (40-bit TS + pass seq) +0x2a, context +0x32, free list +0x36/+0x3e/+0x46, scheduler +0x4a, qos +0x52/+0x56, owner pid +0x5a, policy +0x5e, context update +0x62, `unk_66` = 1, PB +0x6e/+0x76/+0x7e, fragment qid +0x82 | `KickCmd27`, type 0xf, 0xc0 slot (firmware reads 0x88): the same fields at the same offsets (`entries_gpu_va`/`entries`, `slot`, `mark_slot`, `priority`, `dm`, `has_timestamp`, `timestamp`, `unk_32`, `resource*`, `gpu_context`, `bind_context`, `ctx_arg_56`, `process_id`, `ctx_arg_5e`, `global_bit_*`, `pb_state/gen/slot`, `pb_bit`) | **same** (our decode's names are wrong; use the driver's) |
| `KickPredecessor`, tag 0x10: qid +4, previous TS +6, `unk_0e` = 0xfe | `KickRelease27`: slot +4, entry selector +6, parent bit 0xfe at +0xe (firmware reads 0x18; 0x40 slot) | **same** |
| `InitBufferManager`, tag 5 (0x18) | type 5 "buffer-manager bind (0x18)" | same (**inferred** from size) |
| `KickAnnounce`, tag 0xe | in the dispatcher's table; never seen in macOS's rings (3D rings alternate 0xf/0x10) | **unknown** whether 27.2 still takes it as the kick |
| Tiling 0 / Fragment 1 / Compute 3 descriptors | 0 TA (0x9a0), 1 3D (0x2240), 2 blit, 3 compute (0x1040), 4/0x12 barriers | type ids same; layouts not compared |
| `KickEntry` 256 × 0x200: header, mcache, descriptor +0x10, queue +0x18, dependency control +0x20, deps[32] +0x28, event mask +0x128, +0x148, register arrays +0x150 | 256 × 0x200 per DM, entry+0x18 = owning queue, +0x30, +0x128 (parent bits the 0x10 command clears), +0x148 | same where checked (**inferred** beyond those anchors) |

## 15. Device control and events

| | Driver | 27.2 | Verdict |
|---|---|---|---|
| Record | 0x40, 256 slots (`g17/fw/channels.rs:21-23`) | 256 × 0x40 | same |
| Opening | 0x16 | **0x15** (snapshot 01) | renumbered |
| Scheduler-state release | 0x14 (`SchedulerStateRelease`); M5 0x13 | macOS sends **0x13** ("destroy context") | renumbered (**inferred**: 25G83 0x14 and up → −1?) |
| Other host opcodes | 0x08 TvbGrowReply, 0x09 ChannelErrorAck, 0x0a IdlePowerOff, 0x29 ContextKill, 0x2e FreeListRelease (`:343-358`) | macOS sent 0x22 (idle timestamp, many), 0x2e, 0x20 (answer to event 0xd) | **unknown**: the 27.2 dispatcher (types 0x4..0x3b) must be decoded before any opcode above 0x14 is trusted. If 27.2 renumbered by −1, 0x2e is 25G83's 0x2f, not FreeListRelease |
| Event entry | 18 words = 0x48; types 1 stamp, 4 restart, 6 TVB grow, 7 compute fault, 0xc context killed, 0xd free-list grow (`:26-40, 160-172`) | 0x48; 1 completion masks, 4, 6, 7, 0xa, 0xc, 0xd seen | ids same; 0xa unknown to the driver; field layouts not compared |
| Mailbox | 0x81 (44-bit address), 0x84\|0x11 control notify, 0x42 events (`g17/mod.rs:296-336`) | 0x81, 0x83, 0x84\|0x11, 0x85, 0x86, 0x87\|0x10; firmware sends only 0x42 | same core; 0x85/0x86/0x87 to check against the driver's kick/power paths |

---

## 16. What a V27_2 variant needs, smallest first

Each item: the change, then whether our decode answers it.

1. **Interface version per variant**: make `INTERFACE_VERSION`
   (`fw/initdata.rs:33`) a variant field; 27.2 = `[0x04c0, 0x8398, 0x6339,
   0x0c8b]`. *Answered.*
2. **Pointer layout**: `V27_2.pointers = {producer: 0x40,
   recovery_target: Some(0x50)}` (the V26A428 values). *Answered (snapshot).*
3. **Opening-record opcode**: 0x15 instead of 0x16 (`OpeningRecord::PRIMARY`
   must come from the variant). *Answered (snapshot 01).*
4. **QID floor**: 0 instead of 32. *Inferred* from macOS using QIDs 0–6.
   Confirm in the firmware (the 25G83 reason was a bootstrap protocol on
   low QIDs).
5. **MainConfig**: `power_config_va` at +0x481; `unk_18` = 0; set +0x308 =
   4, +0x30c = 100, +0x320..+0x328 = 1, 2, 3 as macOS does. *Offsets
   answered; the meaning of the new words is not.*
6. **Firmware build entry**: a `Build` for 27.2 in `hw/t6040.rs` (`os_version
   [27, 2, 0]`, `text_size 0x64000`, `data_size 0xc4000`, GKTS/ECAP
   entropy offsets, `boot_filled`, `text_sha256`). *Not answered*: compute
   the entropy offsets and digest from our two `__TEXT` dumps (if more than
   the entropy records differ between them, those ranges are `boot_filled`).
7. **RegionC**: a `RegionC27` with the +4 shift and macOS's values
   (`unk_78` → 1, 2, 902; `max_power`). *Offsets answered by value
   alignment; which word is new (0x34 or 0x38) is not.* Copying macOS's
   words through 0x40 sidesteps it.
8. **Status B offsets**: recovery block +0x1e0 (`RECOVERY_INFO` 0x4298,
   `RECOVERY_SLOT_MASK` 0x4ab8, fwctl 0x4ac0/0x4ac8, epoch 0x4ad0, state
   0x4ae0, `HOST_RECOVERY` 0x4af0); +0xe714 = 1 and +0xe718 = 8.
   *fwctl/state/epoch answered (firmware decode + snapshot); info, slot mask,
   host_recovery inferred from position.*
9. **Private cluster and bundle layout**: status B at grid+0x340, power state
   at cluster+0xea80, status A at +0xf180, config at +0xc3440; views at
   bundle +0x2880/+0x34c0/+0x4540/+0xc000/+0xc080; firmware area at
   bundle+0xc880; `WORK_RINGS` 0xc940; `MAIN_CONFIG` 0x1e940; AON table after
   the bundle. *Answered (snapshot).* Still open: whether the firmware needs
   these exact offsets, and what the views and the 0xc0-byte firmware area
   must contain (macOS's contents are in the snapshot, not yet read).
10. **Power state**: macOS's 0x6a8–0x700 block, including +0xc8/+0xcc.
    *Values in the snapshot; field meanings partly decoded
    (`PowerMgmt27`).*
11. **Queue record**: 0x80-byte record in a QID-indexed array; the −4 shift
    from +0x3c; `scheduler_va` at +0x70. *Partly answered*: the head and
    the −4 run are certain, but `policy` at +0x3c, `scheduler_va` at +0x70,
    and the meaning of +0x48..+0x6f and +0x78 are inferred. Capture: a
    queue created, owned and released under macOS (trace its record
    writes); decode the firmware's readers of +0x3c..+0x7f.
12. **Crash-log segment**: accept the firmware's buffer in
    `__DATA_SHARED_RO`. Needs a reserved-memory region for it in the DT
    (aura must reserve `gfx-data-shared-ro`; `docs/gpu/dt` names it only in
    a comment) and `data_segment.rs` to look it up. Also send
    `MSG_LOG_BUFFER` as macOS does. *Answered (trace).*
13. **HwData**: `HwData27_2` with 60 register-map slots, the +5 renumbering
    of T6040 windows 26–43 (`hw/t6040.rs:129-163`), `sgx_sram_ptr`/size,
    the dropped and inserted words, and macOS's values (0x1044 = 0xc, 0x1088
    = 1, `gpu_core` 0x13, core counts 20/20/16, `sched_pause` 150,
    `trace_enable`, +0x2846/+0x284a, flags 2 on empty slots, f32
    relative-performance tables, CS table zero). *Mostly answered.* Open:
    the five new region ids in 0x17..0x1e, the inserted u32 near
    0x2600..0x2614, the object at +0x27e0 (size, contents), `unk_1a64`,
    `gl2_poll_timeout`, and what selects the alt DVFS curve.
14. **PowerConfig**: a 27.2 word list. *Partly answered* (piecewise shifts
    above, from value alignment). Open: the head (+0x0..+0xbf
    differences), words not found at any shift (0x9ec, 0xa70..0xa84, 0xad0,
    0x29bc..0x29d0, 0x2b94, 0x2be8, 0x2eec), where the leakage coefficients
    and the entropy word went. Decode the firmware's reads of
    MainConfig+0x481's target (fn_2ff18 and the perf-state code read
    PowerMgmt27; PowerConfig's reader is not yet identified).
15. **Device-control opcodes and events**: an opcode map per variant.
    *Not answered.* Decode the 27.2 device-control dispatcher (types
    0x4..0x3b, `AGFAcceleratorDrainDeviceControlRing`) against the driver's
    opcode list; trace macOS through a TVB grow (0x08 vs 0x20?), a context
    kill, a free-list release and an idle power-off.
16. **Kick path**: confirm the 27.2 firmware takes `KickAnnounce` (0xe), or
    switch to macOS's 0xf/0x10 pairs; compare `KickEntry` fields beyond
    +0x18/+0x30/+0x128/+0x148 and the TA/3D/compute descriptor layouts
    (0x9a0/0x2240/0x1040) with the driver's render and compute builders.
    *Not answered*: needs the `27.2-triangle` traces decoded at the kick-entry
    level.

Smallest useful milestone: items 1–9 plus 12 and copies of macOS's
blocks for 10, 13 and 14 should get the firmware to accept InitData,
set status A +0x14 and retire the opening record. Items 11, 15 and 16
are needed before the first submission.

---

## 17. Device control in 27.2 (decoded)

Answers §15 and §16 item 15 from the firmware, not from traces. Static
work only. Three sources:

- **27.2**: `build/agx/20261114-boot2/gfx-asc__TEXT.bin`, disassembled
  with LLVM `objdump` (each word emitted as `.inst`). Addresses are
  `__TEXT` offsets, i.e. `0x7ffffc00_0000xxxx`.
- **25G83**: `Firmware/agx/armfw_g16s.im4p` from
  `UniversalMac_26.6.2_25G83_Restore.ipsw`. It is an `rkosftab` with two
  identical images (`a000`, `b000`). Image `a000` starts at file offset
  0x89, and its Mach-O header is stripped, so `__TEXT` vm 0 is image
  offset 0x3fe0. The image is unencrypted. This is the firmware the driver
  models, so each 27.2 handler can be matched with its 25G83 counterpart
  by the fields it reads and what it calls.
- **Driver**: paths as in "Sources and conventions". The data-segment
  globals below are 27.2's: `0x11e9e8` = MainConfig (ctx), `0x126130` =
  RegionC, `0x11f398` = status B (InitData+0xb0, firmware-decode.md).

### Dispatcher

`AGFAcceleratorDrainDeviceControlRing` (27.2 `0x389c`, 25G83 `0x385c`):

- Record pointer = `ctx[+0x1b8] + idx·0x40` (x13). It reads the opcode
  u32 at +0, subtracts 4 and jumps through a table of `ldrsw` offsets
  (27.2: table `0x57c0`, base `0x3a88`, **56 entries, opcodes 0x4..0x3b**;
  25G83: table `0x5284`, base `0x3a3c`, 52 entries, 0x4..0x37).
- Out of range or unused opcodes go to the common tail (27.2 `0x5684`),
  which traces 0x13e and **consumes the record**. Opcode 0x2c panics
  (`fn_47134`, "Unsupported command type ExternalCSRequest") on both
  builds. 27.2 0x25 with byte +4 ≥ 3 also panics.
- **Power-assert accounting.** The tail reads a per-opcode byte from a
  flag table (27.2 `0x5c850`, 25G83 `0x58850`). If it is set, the tail
  increments status B **+0xe718** (25G83 +0xe438). On entry, the drain
  compares that count with the host's tally at **RegionC+0xe55** (25G83
  RegionC+0xe51, the driver's `RegionC::POWER_ASSERT_TALLY`,
  `fw/initdata.rs:1379,1388`). While they differ it calls `fn_36988`
  (power up). The tally moved with RegionC's +4 shift (§16 item 7). The
  27.2 handlers for 0x34 and 0x35 write RegionC+0xe45 and +0xe49 (25G83:
  +0xe41 and +0xe45), which confirms the shift.

27.2 flag table (1 = counted). Opcodes 0x00–0x3f, grouped by 16:

```
0x00-0x0f 0111111111111101
0x10-0x1f 1110001111001111
0x20-0x2f 1101111111011100
0x30-0x3f 1111111111111000
```

Not counted in 27.2: 0x0e, 0x13, 0x14, 0x15, 0x1a, 0x1b, 0x22, 0x2a,
0x2e, 0x2f. 25G83's table differs: there **0x14 is counted** (the
driver's rule) and 0x15/0x16 are not.

### Renumbering: not uniform

Pairing the handlers of the two builds by signature (record fields read,
callees, constants) gives three bands:

| 25G83 opcodes | 27.2 opcodes | Shift |
|---|---|---|
| 0x04–0x0e | 0x04–0x0e | 0 |
| 0x10–0x1b (0x0f was empty) | 0x0f–0x1a | **−1** |
| — | 0x1b (new: cache-maintains MainConfig+0x471 and +0x479, 8 bytes each) | new |
| 0x1d–0x2e | 0x1d–0x2e | 0 |
| 0x2f–0x37 | 0x30–0x38 | **+1** |
| — | 0x3b (new; reads +4 and +0xc, then nothing) | new |

Examples of the pairing: 25G83 0x10 (u128 at +4, u64 at +0x14) = 27.2 0x0f.
25G83 0x16 (opening: global=1, `bl 0x30a8`) = 27.2 0x15. 25G83 0x19
(u128 at +4, 0x50f8) = 27.2 0x18. 25G83 0x31 (clear 0x1800 at +0xc748)
= 27.2 0x32 (clear 0x1800 at +0xc928). 25G83 0x37 (0xbc08/0xbc00) =
27.2 0x38.

So "25G83 opcode ≥ 0x14 → −1" is **wrong**. Of the driver's opcodes, only
the opening (0x16) and the scheduler-state release (0x14) fall in the −1
band. These two are the 26A428 "common26" numbers the driver already uses
for M5 (`fw/m5/initdata.rs:1665`, `fw/channels.rs:353`).

### Driver opcodes → 27.2

| Driver record (`fw/channels.rs`) | Driver op / layout | 27.2 op | 27.2 handler: fields read | Layout | Counted (27.2) |
|---|---|---|---|---|---|
| `OpeningRecord` (`fw/initdata.rs:420-445`) | 0x16, opcode only | **0x15** | `0x4dd4`: sets `0x11f3f0`=1, `0xd6db4`, `bl fn_30ac`; no fields | same | no (also no in 25G83) |
| `TvbGrowReply` (`:386-423`) | 0x08: grew +4, buffer_slot +8, vm_slot +0xc, counter +0x10, subpipe +0x14, halt_count u64 +0x18 | **0x08** | `0x4cdc`: u64 +0x18 must equal status B+0x4ad0 (else trace only, `0x54f4`); +4 (0 → `0x5624` no-grow path); `ldrsw` +8 indexes a 0x38-stride table at `0x71970`; +0xc → `fn_2f984`; +0x10 kept. +0x14 not read on the paths decoded. | same | yes |
| `ChannelErrorAck` (`:580-606`) | 0x09: engine +4, queue_va u64 +8, stamp u64 +0x10 | **0x09** | `0x4c20`: queue = u64 +8; `queue+0x54 −= 1` (event 7 incremented it); trace with +0x10; `[queue+0x10]+0x14 −= 1`, at 0 `fn_2098c`. +4 not read. | same | yes |
| `IdlePowerOff` (`:435-457`) | 0x0a: policy +4 (0 keep/power up, 1 allow) | **0x0a** | `0x4cc0`: `0x11f420` = +4; if 0 `bl fn_36988` (power up) | same | yes |
| `SchedulerStateRelease` (`:459-490`; built `g17/initdata.rs:478-485`) | **0x14** (M5 0x13): id bytes +8..+0xb (page 0x26, 0, 1, 4), page_va u64 +0xc | **0x13** | `0x414c`: bytes +8, +9, +0xa, +0xb; u64 +0xc must equal the slot table `0xcb5d8[byte +0xa]`, and bytes +9/+0xa ≠ 0xff; clears the slot, sets its free bit, `bl fn_1d888`, decrements a counter by byte +8. Same code as 25G83 0x14 (`0x3ee8`). | same | **no** (25G83: yes) |
| `ContextKill` (`:608-629`) | 0x29: page_va u64 +4, cookie u64 +0xc | **0x29** | `0x4278`: page = u64 +4 (invalidates 0x38 bytes); cookie = u64 +0xc. If page[1]==0xff it posts event 0xc {cookie} at once (`0x559c`). Otherwise it queues (cookie, page) at `0x125918` (128 entries) and wakes event bit 37. | same | yes |
| `FreeListRelease` (`:492-518`) | 0x2e: generation u64 +4, buffer_slot +0xc | **0x2e** | `0x4c90`: `fn_2a110(u64 +4, u32 +0xc)`. That function checks `0x73540[slot·0xf0]+8 == generation` and releases. | same | no |

**What sending the 25G83 opcodes does on 27.2:**

- **0x14 is no longer the release.** 27.2 0x14 (`0x3f78`, 25G83's 0x15)
  reads the byte at +0x14 (slot index), the u64 at +4 (a pointer) and the
  u32 at +0xc. Under its lock it writes 0xd to a register, clears
  `ctx[+0x2d0][slot]` and then **stores the u32 at +0xc to the address
  at +4** (`0x4ee0`). A driver release record (+4 = 0, id bytes at +8)
  makes that address `id << 32`, so the firmware writes through a wild
  pointer. The opcode must become 0x13.
- **0x16** is now "store the u64 at +4 to `0x1212a8`" (`0x4e04`, 25G83's
  0x17). It is harmless with a zero record, but it does not open.

### Records macOS sends that the driver does not

| 27.2 op | Handler | What it does | Driver |
|---|---|---|---|
| 0x22 | `0x4db0` | Copies 16 bytes from RegionC+0x98c to `0x11f4d0`; ignores the record. Not counted. In 25G83, 0x22 is a no-op. | Not needed (**inferred**: macOS's "idle timestamp" refresh) |
| 0x20 | `0x4004` → `fn_290ec(w0=+8, w1=+4, w2=+0x30, x3=+0xc, w4=+0x2c, x5=+0x24, x6=+0x1c, x7=+0x14, stack=+0x34)` | Free-list registration: if +0x34 ≠ 0, entry `0x73540[slot(+0x30)·0xf0]` gets {control_va (+0x14), generation (+0xc)}. A different generation already there is released first (`fn_2a110`). Counted. Same handler in 25G83 (0x20 → `fn_26928`). | The driver never sends it on 25G83 either. macOS sends one for every event 0xd and echoes the event: +4 = event stamp, +0xc = new generation, +0x14/+0x1c/+0x24 = event +0xc/+0x14/+0x1c, +0x2c = event +0x24, +0x30 = event slot (+8), +8 = 0x3f, +0x34 = 1 (snapshots 02 and 03). The next 0x2e records release that generation. Whether 27.2 **needs** the 0x20 to continue after event 0xd is **unknown** (the driver works without it on 25G83, and both builds have the same handler) |

### Events (firmware → host, 0x48)

The generic poster is `fn_35cb0` (27.2): it copies a 0x48-byte record into
the ring at ctx+0x1c0/+0x1c8 (channel 13) and sends 0x42 on endpoint 0x20.
Type 1 has its own poster, `fn_35a24`.

| Type | 27.2 builder | Layout read | Driver (`fw/channels.rs:42-108, 159-172`) | Verdict |
|---|---|---|---|---|
| 1 stamp | `fn_35a24` | {1, mask0 u64 +4, mask1 u64 +0xc, u16 +0x14}; the rest is stack contents ("TRSK"/"TACK" fill in the snapshots) | `StampEventRecord` masks +4, diagnostic_pairs +0x14 | same |
| 4 restart | inline at `0x6778` | {4, u64 +4, i32 +0xc (−1 when unattributed, `0x6830`)} | generation +4, stamp +0xc | same (that +4 is the status B +0x4ad0 epoch is **inferred**) |
| 6 TVB grow | `fn_1e730` `0x1ed88`, `fn_1f8f4` `0x1fa94` | {6, i32 +4, i32 +8 (buffer object +0xc), counter +0xc (post-incremented), +0x10, **u64 status B+0x4ad0 at +0x14**} | vm_slot +4, buffer_slot +8, counter +0xc, subpipe +0x10, halt_count +0x14 | same; the reply's +0x18 is checked against the same word |
| 7 channel error | `fn_6d64` (class 0, engine 1, called from `0x163ec`); inline with header constants (7,1) `0x5c698` (`0x14464`, `0x14868`, `0x157ac`) and (7,2) `0x5c6a0` (`0x1a714`) | {7, class +4, engine +8, qid +0xc, stamp +0x10}. Every builder first increments queue+0x54, which ack 0x09 decrements | `decode_channel_error` (`:198-213`): class, engine, qid, stamp | same (25G83 meaning holds) |
| 0xc context killed | `0x55a0` (immediate, from 0x29) and `0x3c3c0` (deferred kill queue) | {0xc, cookie u64 +4} | words[1] \| words[2]<<32 | same |
| 0xd free-list | built at `0x29888` in `AGFHRBResume~`, posted at `0x29d20` | {0xd, stamp +4, slot +8, control_va u64 +0xc, ring_va u64 +0x14, u64 +0x1c, u32 +0x24} | `FreeListEventRecord` stamp +4, buffer_slot +8, control_va +0xc, ring_va +0x14, cookie +0x1c, result +0x24 | same offsets. Snapshot values: +0x24 = 0x10 or 0x18, +0x28 = 4 or a pointer; the driver's `result` reading of +0x24 is **unverified** |
| 0xa | `0x14ca4` in `agfKSMCompletionQueueGetFWDMType~` (completion-queue path) | {0xa, u64 entry+0x54, u64 new value, u32 entry+0x50}. Posted after the firmware raises a monotonic stamp (`[x22] < x23` → `str x23,[x22]`) | not handled; `Event::Unknown` consumes it | **inferred**: a completion/stamp notification carrying a host cookie (entry+0x54). Safe to ignore unless a waiter needs it |
| 9 | same builder as 0xd (`0x298a4`) | {9, +4, +0x14, +0x18, +0x1c = 1} | not handled | unknown; consumed |

So 27.2 keeps every event id and every field offset the driver reads.

### Mailbox endpoint 0x21

`fn_37f88` is registered for endpoint 0x21 at `0x6ad0` and `0x370e4`. It
switches on `(msg >> 48) & 0x3f` and accepts only 3–7. Any other type
**panics** ("Msg of type %u received, which can't be handled!", `0x38088`).
25G83's handler (`0x35180`) is the same apart from the offsets.

| Msg | 27.2 action | Driver |
|---|---|---|
| 0x83 \| x | `x & 3` = engine (3 = none): sets bit (1 << engine) in event group `0x11eb48`; when `x & 0x1c` = 0, counter `0xcf490` +1 | sends `0x83 \| priority<<2 \| engine` (`runtime/render/direct.rs:123`, `queue/compute.rs:3019`): same |
| 0x84 \| 0x11 | sets bit 17 in `0x11eb48` (wakes the device-control drain); low bits ignored | `MSG_CONTROL_NOTIFY` (`g17/mod.rs:324`): same |
| 0x85 | sets bit 32 in `0x11eb48` (25G83: bit 31); payload ignored | not sent. The woken task was not identified (§firmware-decode calls it "halt", **unverified**) |
| 0x86 \| epoch | if the low 44 bits equal status B+0x4ad0 (25G83 +0x48f0): `[MainConfig+0x26c]+4` = 1 (the power object, view 3), sets bit 1 in `0x11eda8`; otherwise ignored | not sent. **Inferred**: a power/resume acknowledgement bound to the recovery epoch |
| 0x87 \| 0x10 | sets bit 36 in `0x11ed80`; payload ignored | not sent. macOS sends it 4 times in boot5, each just before a burst of 0x83 kicks (t = 35.46, 35.82, 95.90, 96.15). The consumer was not identified |
| 0x89 | **panic** | `MSG_POWER_ON_DONE` and `MSG_INITDATA_DONE` are 0x89. `V27_2` inherits `power_on_done: false` (`fw/variant.rs:164,198`), and `MSG_INITDATA_DONE` is sent only for chip 0x8142, so the M4 Pro path never sends them. Keep it that way |

### What the V27_2 variant needs (replaces §16 item 15)

1. **Release opcode 0x13.** Today `scheduler_release` uses 0x13 only when
   `self.m5` (`g17/initdata.rs:478-485`). Make the opcode a variant field
   (V27_2 = 0x13). Sending 0x14 makes the firmware store through a wild
   pointer (above).
2. **Power-assert rule for 27.2.** Counted: 0x08, 0x09, 0x0a, 0x29 (and
   0x20). **Not** counted: 0x13, 0x2e, 0x15. `control_asserts_gpu_power`
   (`g17/initdata.rs:488-494`) uses the 25G83 rule for non-M5, which
   counts the release, so the host tally would run ahead of status B
   +0xe718 forever and keep the GPU powered. The M5 rule
   (`fw/m5/power.rs:10`, 0x08/0x0a/0x29) plus 0x09 is 27.2's rule.
3. **Tally offset RegionC+0xe55** (not 0xe51) on 27.2
   (`g17/initdata.rs:1879-1880` picks `RegionC::POWER_ASSERT_TALLY`).
   This is part of the RegionC27 +4 shift (§16 item 7).
4. Opening 0x15: already in `V27_2.opening_opcode`.
5. No change needed: 0x08, 0x09, 0x0a, 0x29 and 0x2e records; event
   decoding; 0x83/0x84 messages. Optional: decode event 0xa, and send
   0x20 after event 0xd as macOS does, if the free-list path stalls
   (**inferred** need).

## 18. Queues and kicks in 27.2 (decoded)

Sources: the 27.2 `__TEXT` disassembled with llvm-objdump (addresses are
`__TEXT` offsets, = `7ffffc0000xxxxxx`); macOS snapshots `27.2-boot5/02`,
`/03`, `27.2-busy/03`, `27.2-triangle2/05`, `/08` read with
`tools/agx27/snapshot.py`; the driver tree under `g17/`. Caveat for the
traces: macOS recycles its command pool, so ring slots older than a few
hundred items point at overwritten commands. Only the newest items of
each ring, and the fresh `boot5/02` rings, are used as evidence below.

**Headline.** 27.2 is not a 25G83 protocol with shifted offsets. Its
queue record, kick commands and kick-entry gating are the protocol the
driver already implements for M5/J813 (`fw/m5/queue.rs`: the 0x80
`QueueRecord`, the tag-0x10 `Notification` with the *current*
timestamp), minus the M5 host port. The firmware still programs the KSM
queue registers itself. A V27_2 should take the M5/J813 queue and kick
forms and keep the 25G83 command set everywhere else.

### Firmware functions

| Address | What |
|---|---|
| `0x390e0`, `0x391dc`, `0x3926c` | Work-ring consumer, one per DM ring (0 TA, 1 3D, 2 CL). It takes the 0x18-byte slot (`queue_va` +8, DM +0x10, write index +0x14, QID +0x16, first +0x17) and calls `fn_1ba48(record, wptr, first, qid, replay=0, dm)` |
| `fn_1ba48` | Drains one queue. If `first` is set it validates **0x78** bytes of the record (`fn_40270(rec, 0x78)` at `0x1ba84`). Reads `rec+0` (pointer block: `+0` done, `+0x60` entries, `+0x50` the write index on replay), `rec+8` (item ring) and `rec+0x1c`. Writes `rec+0x1c` = wptr (`0x1bb1c`), block `+0x30` = wptr (`0x1bb24`) and block `+0` = consumed position (`0x1bbb8`). Dispatches each item through `fn_1a5c8`. If a command blocks, it parks `{record, dm, wptr}` at `0xd3100 + qid*0x10` with a bit in the 128-bit map at `0xd30f0`. `fn_1bbd8` resumes those |
| `fn_1a5c8` | The command dispatcher. It reads the u32 tag, then uses a 19-entry jump table at `0x1b9fc`. In replay mode (arg 4 set, from `fn_17c44`) only tags 0–5, 0xc, 0xe, 0xf and 0x10 run (mask `0x1d03f` at `0x1a630`); the others are skipped as done |

### 1. The queue record (0x80, = the driver's M5 `QueueRecord`)

macOS keeps the records 0x80 apart in an array at `K+0xc0000000`,
indexed by the **KSM QID** (kick-entry +0x18 = `base + qid*0x80` on every
entry of every ring scanned). The firmware never indexes that array:
the record VA reaches it through the work slot (+8) and the kick entry
(+0x18). So the array is macOS's allocation choice, and any 0x80-byte
(0x78 used) record anywhere works (**inferred** from the absence of any
array access).

| Off | Firmware | macOS values | Driver 25G83 `QueueRecord` (0xc0) | Driver M5 `QueueRecord` (0x80) |
|---|---|---|---|---|
| +0x00 | pointer block; read by `fn_1ba48` | per queue | `pointers_va` +0 | `pointers_va` |
| +0x08 | item ring; read | per queue | `items_va` +8 | `items_va` |
| +0x10 | job list. Tags 0/1/2/3/7/9 link work into it; tag 4 and completion bump job-list +0x14 (`0x1a73c`) | `K+0x18*n` | `job_list_va` +0x10 | `job_list_va` |
| +0x18 | — | 0 | `unk_18[0..4]` | `reserved_18` |
| +0x1c | **firmware-written** consumed write index (`0x1bb1c`) | = pointer `+0x30` | `unk_18[4..8]` | `reserved_18` |
| +0x20 | — | 0 | `unk_18[8..]` | `reserved_18` |
| +0x24 | no reader found | −1 | `unk_24` = −1 | `sentinel_24` = −1 |
| +0x28, +0x2c | no reader found in dispatch or completion | priority ×2 (0, 2, 3 seen) | `priority[2]` +0x28 | `priority` |
| +0x30..+0x35 | no reader found | class 0: `00 00 ff ff ff ff`; 2, 3: zero | `unk_30[6]` | `reserved_30` via `scheduling_words` |
| +0x36 | no reader found | class 0, 2: 0xffff; class 3: 0 | `unk_36` = 0xffff | `sentinel_36` (class 3 → 0) |
| +0x38 | no reader found | class 0: 1; 2, 3: 0 | `unk_38` | `reserved_38` |
| +0x3c | no reader found | **policy**: 1 (class 0), 2 (class 2), 0 (class 3) | `unk_3c` (driver's `policy` is at +0x40) | `policy` +0x3c |
| +0x40 | no reader found | −1 | `policy` | `sentinel_40` = −1 |
| +0x44 | no reader found in dispatch or completion (`fn_17c44` reads a +0x44, unconfirmed as this field) | **owner pid** (0xa4, 0x153, 0x1dc…; = 0xf command +0x5a) | `unk_44` | `owner_pid` +0x44 |
| +0x48..+0x53 | — | 0 | `owner_pid` +0x48, `unk_4c` | `reserved_48` |
| +0x54 | **firmware-written**: +1 per finished command (dispatcher tag 4 at `0x1a6f0`; completion at `0x1443c`, `0x14840`, `0x15784`) | counts | `unk_4c` | `reserved_48` |
| +0x58..+0x67 | — | 0 | `unk_4c` | `reserved_48` |
| +0x68 (u64) | **firmware-written**: accumulated busy time, `rec+0x68 += end − start` at completion (`0x15078`, `0x152b0`, `0x15564`, `0x15998`) | grows | `unk_4c` | `reserved_48` |
| +0x70 | scheduler page; no record reader found (the firmware takes it from 0xf +0x4a) | `K+0xc07d0000 + 0x40*owner` (= 0xf +0x4a) | `unk_4c` (driver has `scheduler_va` at +0x9c) | `scheduler_va` +0x70 |
| +0x78 | outside the validated 0x78 bytes | 0 | — | `reserved_78` |

The class-dependent words (+0x30..+0x3c) match
`fw/m5/queue.rs:QueueRecord::scheduling_words` for every class macOS used:
(0, 1) in boot5/triangle2 QIDs 0, 1, 6, 16; (2, 2) in QIDs 2–5, 10–15,
26–29; (3, 0) in QIDs 19 and 20. Class (1, 0) was not seen. The fields
with no reader found are probably read by the scheduler or recovery
paths (`fn_17c44`, `AGFHRBResume~`). The host must still write them as
macOS does.

### 2. Command types (dispatcher jump table)

| Tag | Handler | Bytes read | What 27.2 does |
|---|---|---|---|
| 0 TA | `0x1a674` | 0x9a0, + 0xc8 at [+0x10] | legacy direct TA: `fn_21014(dm, job_list, [+0x10], [+0x8ce])` |
| 1 3D | `0x1aa60` | 0x2240, + 0xc8 at [+0x20] | the same with `[+0x2168]` |
| 2 blit | `0x1a950` | 0xa00 | the same |
| 3 compute | `0x1a978` | 0x1040 | the same with `[+0xf68]` |
| 4 barrier (32-bit) | `0x1a840` | 0x48 | waits for a stamp; macOS puts these in rings |
| 5 InitBufferManager | `0x1a8c0` | 0x18; PB state 0x90 | `fn_2f984(pb_state=[+0xc], ctx=[+4])`: the PB init through MMIO (+0x18000/+0x1c800/+0x1e820) |
| 6 PMRebuild | `0x1b9ac` | — | fatal ("must not be received in SKSM") |
| 7 | `0x1aae4` | 0x60 | small job, [+0xc] 0xc8 |
| 9 | `0x1a93c` | 0x88 | small job, [+0xc] 0xc8 |
| 0xc | `0x1aa88` | 0x18; object 0x68 | qid u16 +4, ts +6, object +0xe. If obj+0x54 ≠ 0: entry+0x148 \|= 3, else obj+0x5c = entry |
| **0xe KickAnnounce** | `0x1a9a0` | 0x18 | qid u16 +4, count u16 +6, ts +9 (trace only). KSM select register `+0x103a8` = qid, `+0x21018` = count; firmware state `0x11d420[qid*0x28+0x20] \|= 2`, bit qid in `0x11e820`, `0xcc810 += count` |
| **0xf QueueConfig** | `0x1a774` (+ `0x1ac14`.., `0x1b06c`..) | 0x88 | see below |
| **0x10 KickPredecessor / Notification** | `0x1ab50` | 0x18 | qid u16 +4, ts u64 +6, bit u32 +0xe. Entry = kick-table[qid].fw_ring + (ts & 0xff)*0x200; **clears bit `[+0xe]` of the 256-bit map at entry+0x128** (`0x1abd4`), then writes all-ones to KSM +0x210e0/+0x210d8 |
| 0x12 barrier (64-bit) | `0x1a69c` | 0x48 | |
| 8, 0xa, 0xb, 0xd, 0x11, >0x12 | `0x1b9c4` | — | fatal "Unhandled : Invalid command type" |

0xf in detail. It reads `unk_04` +4, kick ring +8, firmware alias +0x10,
qid u16 +0x18, install u16 +0x1a, priority +0x1e, DM +0x22 (≥3 is fatal
at `0x1ad68`), seed-valid +0x26 → seed +0x2a stored at `0xcc820[qid]`,
context +0x32, free list +0x36, PB +0x6e. With **install ≠ 0** the
firmware itself fills the per-QID kick table `0xce058 + qid*0x28`
(+0 valid, +8 the alias, +0x10 the ring, +0x18 `unk_04`/priority term,
+0x20 DM) and programs the KSM. It invalidates the old entry (`+0x21078`
or `+0x21080`), selects the QID (`+0x103a8`) and writes the descriptor to
`+0x21008` = `(dm+1)<<60 | ring & 0x7ffffffffe0 | unk_04<<48 |
(3*(4-prio)-2)<<54`. That is `kick::ksm_slot_descriptor`. It then sets
validity at `+0x21068` / `+0x21070`. With **qos_update** (+0x52) set, it
validates 0x38 bytes of the scheduler page at +0x4a. That page holds
`queue_table_index` (byte +0), `pid_table_index` (byte +1, 0xff = none),
state (byte +2, set to 4), priority (+3), policy class (+4, via the
table at `0x5ec05`) and QID bitmaps (+0x12/+0x1a). It also uses QoS slot
+0x56, pid +0x5a and policy +0x5e. A bad index is fatal: "Invalid Index
in Scheduler State!". Every offset matches `QueueConfig`
(`fw/queue.rs:437-505`).

So **0xe is still a valid kick in 27.2.** It is the firmware-side KSM
kick: it advances the QID's kick count and does not touch the entry's
event map. **0xf + 0x10** is what macOS uses. 0xf (re)configures the
queue every time, and 0x10 releases the *current* entry by clearing its
gate bit 254 (0xfe). macOS never sends 0xe, never writes the KSM from the
host (no MMIO in the traces), and never puts a tag 0/1/3 descriptor in
a ring.

### 3. What macOS writes per submission (traces)

Every ring in every snapshot is strictly `0xf, 0x10` pairs, plus a few
tag 4 barriers (0x48, separate pool), plus **tag 5 lead commands** on
TA queues (10 in triangle2 QID 7). For one kick of queue *q* at kick
timestamp *t*:

1. **Kick entry** at `ring + (t & 0xff)*0x200` (see §5 below). It is
   written with **event bit 254 set** (word 3 bit 62). Evidence:
   `boot5/03` QID 5's newest entry (ts 0x19) has `[0,0,0,1<<62]` while its
   0xf/0x10 sit unconsumed (producer 0x30, done 0x2e). Every released
   entry shows 0 there.
2. **Tag 5** `{tag, ctx u32 +4, pb_slot u32 +8, pb_state u64 +0xc,
   stamp u32 +0x14}` before a TA kick that needs it. This is exactly the
   driver's `InitBufferManager`, e.g. `ctx 1, slot 3, pb
   0xfffffc20c09f8000, stamp 0x500`. It sits in its own 0x40-stride pool.
3. **0xf** (0xc0 slot, 0x88 read), on **every** kick, render and compute.
   First kick of a QID: `install 1, seed_valid 1, seed 0, qos_update 1,
   context_update 1`. Later kicks: `install 0`, `seed = (t-1) | pass_seq<<40`
   (render; e.g. seed 0xb1_000002b4 then ts 0x2b5), `qos/context_update 0`.
   Compute: `seed_valid 0`. Always `unk_66 = 1` and zero from +0x86 on.
   On TA queues, +0x82 = the paired 3D QID (26→27, 7→8, 0→1, 14→15), as
   in the driver's non-M5 `fragment_qid`. +0x3e (free-list generation) is
   often all-ones ("unchanged").
4. **0x10** `{0x10, qid u16, ts u64 = t (current), 0xfe u32, zero to
   0x18}`. This is byte for byte `m5::queue::notification(qid, t)`.
   boot5/02: QID 0's first pair is `0xf(install, seed 0)` then `0x10 ts=1`;
   the second is `0xf(seed 1)` then `0x10 ts=2`.
5. Producer at pointer +0x40, a work slot on the DM's work ring, then
   doorbell `0x83|0x10` followed by `0x83 | prio<<2 | dm` (0/1/2/8/9/0xa
   seen). The meaning of `0x83|0x10` is **unknown** (the doorbell handler
   was not decoded). The driver sends only the second.

The QIDs start at 0 (boot5: QIDs 0–6 installed in order). macOS's
3D/compute event-map words are as follows. 3D: only the gate. Compute:
`[0, 1<<ctx, 0, 0]` kept after release (event 64 + context, the same as
`m5::compute::kick_event_mask` for the J813). The driver's 25G83 compute
mask is `[0,0,4,0]`.

**The driver's sequence and 27.2.** The non-M5 path (`render/publication.rs`
"[lead], descriptor, [configuration], announcement"; compute: [config],
`KickAnnounce`, optional `KickPredecessor(qid, parent)`) puts the work
descriptor in the ring. 27.2 dispatches tags 0/1/3 as **legacy direct
work**: it validates 0x9a0/0x2240/0x1040 bytes and links the descriptor
into the job list through the pointer at +0x10/+0x20 and the stamp
pointer at +0x8ce/+0x2168/+0xf68. The driver's kick-entry descriptors are
not that layout, so expect a fault or a stuck job list. **Not
acceptable.** `KickAnnounce` is accepted. A 25G83-style
`KickPredecessor(qid, previous)` clears bit 254 on the *previous* entry,
which is harmless when that bit is not set. Dropping the descriptor item
alone might work with 0xe, but that path is untested by macOS
(**inferred**). The M5/J813 path, `items = [lead], config, notification`
(`publication.rs`: `if !m5 { push(descriptor) }`), is exactly macOS's
27.2 sequence.

### 4. QID limits

No reserved QIDs. The only writer of the per-QID kick table (`0xce058`)
is 0xf with install (the other 24 code references only read it). macOS
installs QID 0 first. Limits: kick table 128 × 0x28 (ends at `0xcf460`,
where the next table starts); queue bitmaps two u64s (`0x11e820/828`,
`0xd30f0/f8`, KSM valid low/high split at 64); parked-queue table
128 × 0x10. So **QIDs 0–127**: `QID_MAX` 0x7f holds and the floor is 0.
No bound check was found on the work-slot QID byte. The host must keep
it below 128. A record array, if kept, is 128 × 0x80 = 0x4000.

### 5. KickEntry (0x200)

Firmware reads (beyond the KSM hardware): +0x18 queue record (completion
validates 0x78 of it), +0x20 low 32 bits (valid-dependency mask,
`fn_13570`), +0x28.. dependencies (qid bits 46:40, ts 39:0), +0x128..+0x147
event map (0x10 clears a bit), +0x148 (0xc sets bits 0–1). macOS entries,
all 256 slots of every ring scanned, compared with `KickEntry::new`:

| Off | macOS | Driver | |
|---|---|---|---|
| +0x00 header | ts<<2, qid<<42, prio<<59, bit 58 on about half of the 3D entries | same encoding | same; MCache use is optional |
| +0x08 mcache, +0x10 desc, +0x18 queue | — | same | same |
| +0x20 bits 31:0 mask, 39:32 QoS slot, 47:40 class | 0xc TA, 0x18 3D, 0x8 CL | `TA_QOS_CLASS` etc. | same |
| +0x20 bits 63:48 | **0x0fa0** on every entry | `UNK_DEPENDENCY_CONTROL` 0xffff | **differs** |
| +0x28 deps | barriers then parent (`qid<<40 \| ts`) | same | same |
| +0x128 event map | gate 254 while pending; compute `1<<(64+ctx)` | render 0; compute `[0,0,4,0]` | **differs** |
| +0x148, +0x170 | 0 | 0 | same |
| +0x150 register arrays | addr>>5 / checkpoint | same encoding | same (descriptor layouts not compared) |
| +0x178 | 0x3fffffffffffff | `UNK_178` | same |
| +0x180, +0x188.. | 0 | 0 | same |

### 6. InitBufferManager (tag 5) and `lead_commands`

Still valid. The firmware reads ctx +4 and PB state +0xc (0x90 bytes;
the slot comes from PB state +0xc). macOS 27.2 writes the full driver
layout, including slot +8 and stamp +0x14, as a lead item on TA queue
rings. The same PB init (`fn_2f984`) is also reached from
DrainDeviceControlRing (`0x4d58`) and `fn_2f5b4`. **Keep
`lead_commands: true`.**

### 7. Driver changes for V27_2

1. **Queue record**: use the 0x80 layout of `fw/m5/queue.rs::QueueRecord`
   (policy +0x3c, −1 at +0x40, owner pid +0x44, `scheduler_va` +0x70, the
   `scheduling_words` table) for V27_2, instead of the 0xc0 `QueueRecord`.
   Allocate 0x80 per record; any placement works.
2. **Kick items**: a variant rule, e.g. `kick_form: Notification`, that
   publishes `[lead 5], QueueConfig, Notification(0x10, qid, current ts,
   0xfe)` for render and compute, the J813 render path without its
   M5-only parts. It must not push the descriptor into the item ring and
   must not use `KickAnnounce`/`KickPredecessor(previous)`.
3. **QueueConfig on every kick** (macOS never omits it): set
   `send_config`/`present` always for V27_2. The seed rule is as today:
   render `prev().completion_value(pass)`, first kick seed 0 with install,
   QoS and context update; compute `completion_seed: None`. Keep
   `unk_66 = 1`. TA +0x82 = fragment QID (non-M5 `QueueConfig::new`, not
   `m5::queue::config`'s parameter-manager form).
4. **KickEntry gate**: set event 254 (`[.., .., .., 1<<62]`) on every V27_2
   kick entry before publishing, render and compute (compute **inferred**;
   render observed). Compute mask: macOS uses `1<<(64+ctx)` in word 1;
   take `m5::compute::kick_event_mask`'s J813 branch plus the gate
   (**inferred** need).
5. **`dependency_control` bits 63:48 = 0x0fa0** for V27_2 instead of
   0xffff (**inferred** need; a per-variant constant).
6. **`qid_floor: 0`** (QIDs 0–127; `QID_MAX` unchanged).
7. Unchanged: `registration: Firmware` (0xf with install programs the
   KSM), `lead_commands: true`, `PointerBlock` (V26A428 layout, already
   set), `WorkSlot`, `QueueConfig` offsets, `KickEntry` offsets and the
   header and dependency encodings, QoS classes 0xc/0x18/0x8.
8. Doorbell: macOS sends `0x83|0x10` before each `0x83|prio<<2|dm`.
   **Unknown** whether the firmware needs it. Cheap to copy.

### 18.1 Why a consumed kick does not run

Symptom (first render of the patched driver): rings advance and the job
list empties, but there are no stamps and no firmware complaint. Below
is what the 27.2 firmware does with each suspect.

**(a) Free-list slot +0x46 = 0x81, generation 0.** Not a cause. The
binding is skipped only when the generation +0x3e is all-ones
(`0x1b6ac`). Otherwise the firmware calls `fn_29f30(fl_va=+0x36,
slot=+0x46, gen=+0x3e, ctx=+0x32, qid, install)` (`0x1b6d0`).
- **Slot table** at `0x73540`, stride **0xf0** (`slot<<8 − slot<<4`,
  `0x29f6c`), with no bound check. The next table starts at `0x82540`
  (`0x73540 + 256*0xf0`), so slots 0–255 are valid and 0x81 is in range.
- **Entry fields:** +0 fl VA, +8 generation, +0x10 ctx, +0x14 fl+0x10,
  +0x78 a 128-bit QID map, +0xe0 fl+0x5c.
- **Generation use:** if it differs from the stored one, the firmware
  validates 0x68 bytes of the free list and unbinds the old one
  (`fn_2a110`). Generation 0 against a fresh (zero) entry skips only
  that, and the bind still happens (`0x29fb0`).
- **Per-QID map** at `0x82540`, stride 0x38, 128 QIDs.

**(b) QIDs 34/35.** Not a cause. Every per-QID structure in the kick
path is 128 wide:
- kick table `0xce058` (stride 0x28);
- per-QID free-list map `0x82540`;
- PB table `0x84300` QID maps;
- kicked map `0x11e820/828`;
- parked map `0xd30f0/f8`;
- scheduler-page QID maps (+0x12/+0x1a, `0x1b36c`).

The KSM valid and invalid registers are chosen by `qid < 64`
(`0x1ad28`, `0x1b214`). No 32-bit QID mask exists in the 0xf, 0x10,
0xe or ring-drain paths. "FW Build running in SKSM Enabled mode"
(`fn_2c954`) is a build banner; macOS's boot prints it too. No path drops
a kick silently on a QID.

**(c) First config (install, QoS and context update, seed 0).**
Identical to macOS (boot5/02 QIDs 0–5). The scheduler page: a fresh
driver page (`fw/context.rs` `Scheduler::init`: bytes 0/1 = 0xff, +5 = 1,
+0x26 = 2, +0x33 = 0xff) is byte for byte macOS's unused page. On the
first `qos_update` the firmware fills it:
- `pid_table_index` byte +1 is allocated at `0x1b840`;
- `queue_table_index` byte +0 is set by `fn_11ab4` from the pid;
- state +2 = 4, priority +3, policy class +4, the QID bit, and QoS slot
  +0x33 via `fn_1db90` (`0x1b6a4`).

Its only check is "Invalid Index in Scheduler State!" (`0x1b808`), and
that would print. With `context_update` set, the firmware sets or
clears bit ctx in KSM +0xd8f0 according to +0x66 (`0x1b794`), so a
context must be below 64. Context 5 is fine.

The descriptor anchors also match the driver's 25G83 descriptors.
Completion (`fn_137d0`) reads TA +0x8a6/+0x8ce/+0x8fe, 3D
+0x2140/+0x2168/+0x2198 and CL +0xf40/+0xf68, which are the driver's
`stamp_va`/`current_id`/`timestamp_start_va` offsets. Once the hardware
completes an entry, the stamps go where the driver expects.

**What can leave a consumed kick unrun with no message:**
1. **The gate is not cleared on the entry the KSM reads.** 0x10 clears
   bit `[+0xe]` at `table[qid].fw_alias + (ts & 0xff)*0x200 + 0x128`.
   The address comes from **0xf +0x10** (`0x1ac1c`, `0x1aba4`), while
   the KSM fetches from **0xf +8** (`0x1ad70`). If the alias at +0x10 is
   not the same memory as +8, or the 0x10 names another QID or ts, the
   firmware clears the bit elsewhere. The entry then stays gated forever,
   silently.
2. **The KSM cannot fetch the ring.** +8 goes into the KSM descriptor
   masked to `0x7ffffffffe0`. macOS uses its low alias (`0x72_00xx_xxxx`);
   the register-array words in the entry use the same window.
3. **GIN-1114.** If HwData+0x2710 (`gin1114_swwa`, copied to `0x11e860`
   by `fn_35604`) is **3**, every newly installed TA queue (DM 0) is
   halted with reason 7 (`0x1af54`, "GIN-1114 - Halting newly created
   TA queue", logged once). macOS uses 2, which skips this.
4. The `0x83|0x10` doorbell is not it. Per §17 it only raises the engine-0
   event bit, and the rings already advance.

**Recommendation, in order:**
1. After the first kick's 0x10 is consumed, read back the TA and 3D
   entries' +0x140 word, and dump the firmware kick table entry
   `0xce058 + qid*0x28` if the proxy allows.
   - If bit 62 is still set, fix the 0xf +0x10 alias, or the 0x10's
     qid/ts. **This is the most likely cause.**
   - If it is clear, check that 0xf +8 is the KSM-visible low alias of
     the same ring.
2. Confirm HwData+0x2710 = 2.
3. Only then align the rest with macOS:
   - `qid_floor` 0 and free-list slots below 128 are cheap, but this
     decode shows they are not the cause;
   - a non-zero free-list generation;
   - copying the `0x83|0x10` doorbell.

### 18.2 After the 0x10: who starts the entry (first render, q34/q35)

Read-back (patched driver, timeout): the gate is clear on both entries;
the pass records are 0; queue record +0x1c/+0x54/+0x68 are 0; the
pointer blocks read done = `+0x30` = producer (3 TA, 2 3D).

**The firmware does not pick entries; the KSM hardware does.**
- No firmware code reads a kick entry's dependency words or event map
  before the work starts. The only readers of entry +0x128..+0x147 are:
  - the 0x10 handler (`0x1abd4`, clears the bit);
  - a recovery or preemption path in `fn_39a14` (`0x3a944`);
  - `fn_21eb0`.
- Dependencies are checked by firmware only *after* the fact, at
  completion: `AGFKSMCompletionEntryAreParentsReceived` (`fn_13570`)
  against the per-QID mirror `0xccc20 + qid*0x18` {valid byte, last
  completed ts}. It reports through the fatal "All parents of KSM kick
  queue entry … not received", so it would have printed.
- The firmware's whole part in starting a kick is:
  1. 0xf with install: KSM select `+0x103a8`, descriptor `+0x21008`,
     valid `+0x21068/70` (§18).
  2. 0x10: clear bit 254, then write all-ones to KSM `+0x210d8/+0x210e0`
     (`0x1abf0`). These are MMIO stores; no firmware code reads them back.
- "SKSM Enabled mode" (`fn_2c954`) is a banner; the "SKSM non idle"
  strings are in the idle and nap code (`AGFHALMCWWaitForIdle~`). No
  software dispatcher scans the rings of kick entries.
- No 32-bit or kicked-bitmap gate applies to the 0xf+0x10 path:
  - `0x11e820` and the `0x11d420[qid]` state are set by install and by
    0xe only;
  - `0xd30f0` parks a *work ring* only when a command returns "blocked"
    (`0x1bb90`). That would leave done < producer, which the read-back
    rules out.

**First-kick parent dependency: not the problem.** macOS's first kicks
on fresh queues are the same shape as the driver's:

| Queue | Header | Dependency control | dep0 | dep1 |
|---|---|---|---|---|
| boot5 QID 0 TA, ts 1 | `…0004` | `0x0fa00c0000000001` | `0` = (q0, ts0) | — |
| boot5 QID 4 TA, ts 1 (prio 2, QoS slot 2) | `0x1000100000000004` | `0x0fa00c0200000001` | `0x0000040000000000` = (q4, ts0) | — |
| boot5 QID 1 3D, ts 1 | | mask 3 | (q0, ts1) | (q1, ts0) |
| driver q34 TA | `0x1000880000000004` | `0x0fa00c0200000001` | (q34, ts0) | — |

All of these ran under macOS. The driver's q34 TA differs from macOS's
QID 4 only in the QID. `KickTimestamp::FIRST` = 1 with `parent()` =
`ZERO` produces exactly this, so a ts-0 parent on the own queue is
satisfied for a freshly installed queue. Nothing needs seeding beyond
0xf `seed_valid=1, seed=0`. That seed goes only to the firmware's
`0xcc820[qid]` (`0x1a7e0`), which completion and the TVB code use, not
the hardware.

**The read-back contradicts itself, so the driver writes the record
after the drain.** `fn_1ba48` stores `record+0x1c` = producer
(`0x1bb1c`) and pointer-block `+0x30` (`0x1bb24`) *before* dispatching.
At the end it stores block `+0` (`0x1bbb8`). All three go through the
same record pointer, the one from the work slot. Block `+0`/`+0x30` = 3
with record +0x1c = 0 means one of two things:
- the host rewrote the record after the firmware drained it. Candidates:
  `render/memory.rs` `set_owner(.., rewrite=true)` (a read-modify-write
  of the whole M5 record), or a re-run of graph initialisation
  (`QueueRecord::new` at `memory.rs:188`);
- or the work slot names another record that shares the pointer block.

A rewrite also clears +0x54 and +0x68. So **+0x54/+0x68 = 0 does not
prove that nothing ran**, and both counters move only at completion
anyway (`0x1443c`, `0x15078`). "Released but never completed" and
"started and hung in the TA" cannot be told apart from these words.

**Conditions that leave a released entry unrun or unfinished with no
message:**
1. The KSM cannot fetch the ring or the register arrays. The 0xf +8 ring
   VA goes masked into the KSM descriptor (`0x1ad70`), and the entry's
   +0x150.. bindings are in the same low window. macOS uses `0x72_…`
   and the driver uses `0x70_…`. That works only if it is mapped where
   the KSM translates (context 0, lower half). This cannot be decided
   statically.
2. The queue is not valid in the KSM. Install writes the valid bits only
   if they are not already set (`0x1ad30`, `0x1add4`). A queue left valid
   from an earlier install with a stale descriptor is invalidated first
   (`0x1ad3c..0x1ad58`), so this is self-healing.
3. A firmware halt mask on the queue:
   - GIN-1114 (`0x11e860` = 3: new TA queues halted, reason 7, logged once);
   - with `0xd60a0 ≠ 0` (a counter that `fn_1e730`, `fn_1f608` and
     `fn_1f8f4` decrement), a newly installed **3D** queue is halted
     (`fn_13440`, `0x1ae80`) until the callback `fn_1e710` fires. That
     counter belongs to the PB/TVB path. It is probably 0 at the first
     render, but the type 5 lead command runs the same PB code
     (`fn_2f984`).
4. The work starts but the TA never finishes: a bad register program or
   descriptor contents. That gives the same read-back. The firmware's
   descriptor anchors match (§18.1). The 27.2 register programs were not
   compared.

**Most likely next fix.** The kick path itself now matches macOS (dep0
included). Stop the host from rewriting live records first:
- For V27_2 render pairs, never store a whole `m5::queue::QueueRecord`
  after the first publication. Write only host words: +0x10, +0x28..+0x44
  and +0x70.
- Leave +0x18..+0x27 and +0x48..+0x6f, which the firmware writes, alone.

Then re-run and read +0x1c. If +0x1c = producer but +0x54 stays 0, the
entry did reach the KSM. Next:
1. Read the KSM valid bits (sgx `+0x21068`, `+0x21070`; QIDs 34/35 are bits
   34/35 of the low word).
2. Check whether HwData+0x2710 is 2.
3. Try the macOS ring window (`0x72_…`) for the KSM ring and register
   arrays.
4. Compare the 27.2 TA register program with macOS's
   (`27.2-triangle2` snapshot 08, QID 26 entry +0x10 / +0x150).

### 18.3 The install path, and who programs the KSM

New device evidence (first render, TA q34 / 3D q35):
- power is on;
- the firmware sends no 0x42 at all;
- after the timeout, sgx `+0x21068/+0x21070/+0x21078/+0x21080` read 0,
  so bits 34/35 are not valid.

**(a) 0xf with install = 1, end to end.** `KSM` below is the base at
`[0x11fbf8]` (sgx; the read-back matches its offsets).

1. `0x1a780..0x1a7a4`: read qid +0x18, ring +8, DM +0x22, priority +0x1e,
   `unk_04` +4, context +0x32, free list +0x36, PB +0x6e.
2. `0x1a7a8`: if seed-valid +0x26, store the seed +0x2a at `0xcc820[qid]`
   (firmware only).
3. `0x1a7e4`: **install = 0 → skip to the scheduler part (`0x1b06c`).**
4. `0x1a7ec..0x1ac40`: firmware kick table `0xce058 + qid*0x28`:
   - +0 valid = 1;
   - +8 = 0xf +0x10 (firmware alias), +0x10 = 0xf +8 (KSM ring);
   - +0x18 = `unk_04`, +0x1c = `3*(4-prio)-2`, +0x20 = DM.

   It moves the QID bit between the per-DM maps `0xcf460 + dm*0x10`.
5. `0x1ac44`: **`if [0x12034c] != 0` → skip every KSM write (`0x1ae00`).**
   `0x12034c` is **HwData+0x2730**, copied at boot (`0x324b0`).
   macOS sets it to **1** (boot5 HwData), and so does the driver (it
   calls it `trace_enable`).
6. Only when that word is 0 (`0x1ad0c..0x1adfc`):
   - if the queue is already valid (`KSM+0x21038/+0x21040`, low/high
     by `qid<64`), invalidate it (`+0x21078` low / `+0x21080` high);
   - `KSM+0x103a8` = qid (select);
   - `KSM+0x21008` = `(dm+1)<<60 | ring&0x7ffffffffe0 | unk_04<<48 |
     (3*(4-prio)-2)<<54`;
   - shadow `0x11d420[qid*0x28+0x20] |= 1` and bit qid in `0x11e820`;
   - if not yet valid, set the valid bits (`+0x21070` high, `+0x21068`
     low).
7. `0x1ae00..0x1b06c`: halt bookkeeping. `0xd60a0 ≠ 0` halts a new 3D
   queue; `0x11e860` = 3 (GIN-1114) halts a new TA queue.
8. `0x1b06c..`: with `qos_update`, the scheduler page; then free-list
   bind `fn_29f30`, PB bind (`0x84300 + slot*0x50`), soft-fault context
   bit (`KSM+0xd8f0`), and `0x70428[qid*0x28+0x23]` from +0x6a.

So **with HwData+0x2730 = 1 the firmware never installs a queue in the
KSM.** That is exactly what your read-back shows: valid bits 0 after
an install=1 config.

The same word gates other host-port setup:
- `AGFASchedulerProcessPowerKick` (`0x39478`): at power-up it writes
  `KSM+0x10a08 = 0x200000` and `KSM+0x211b0 = 3` (**inferred**: enables
  the host submission port);
- `0x3953c`, `0x39778`: power and idle decisions;
- completion (`0x14518`): also links work into the job list
  (`fn_21014`).

The firmware's own KSM role in this mode is **save and restore**.
`fn_1710c` saves, per QID, `+0x21008/+0x21010/+0x21020/+0x211e0` into
the shadow `0x11d420` (`0x17748..0x1777c`), and restores them, the
valid masks (`0x11d400 → +0x21068/70`) and the completion-ring bases
around power cycles. Whoever programmed the KSM before, it carries
that state over; it never creates it.

**"SKSM" is not a software KSM.** The banner (`fn_2c954`, `0x2c988`) is
printed unconditionally. No firmware loop scans kick rings or
dependencies. The hardware KSM dispatches. The only firmware writes
per kick are:
- 0x10: clear gate, then `+0x210d8/+0x210e0` = all-ones;
- 0xe: `+0x103a8` = qid, `+0x21018` = count.

With HwData+0x2730 = 1, the queue install (descriptor and valid bits)
must come from the **host**. The driver's M5 `HardwareSubmission`
(`fw/m5/queue.rs`) is that path:
- invalidate `+0x21080/+0x21078`;
- port `+0x4090` = tag, `+0x4098` = descriptor;
- valid `+0x21070/+0x21068`;
- per kick, port `tag+0x10` with 1.

macOS's HV traces record no MMIO, so they could not show this.
(**Inferred** for M4 Pro 27.2 macOS; the firmware side is certain.)

**(b) No 0x42.** The firmware sends 0x42 only after posting to the
event or trace rings: completion (type 1), faults, timeouts, grow
requests. Nothing started, so nothing completed. macOS's thousands
are completions and idle/power traffic. The silence follows from (a);
it is not a separate fault.

**(c) Object IDs.** The firmware reads them only after work is done.
TA `+0x8ce`/`+0x86e` are read by completion and the TVB/PB code
(`fn_137d0` `0x13f38`, `fn_1e730`). They cannot block a start the KSM
never sees. Their required format was not decoded. macOS's look like
`{tag byte, 24-bit counter}` (`0x0a00d1e8`). Revisit once work runs.

**(d) Tiler status word.** It is not read before start either.
macOS's register value `0x10_0007_9ac1` for `K+0x1839ac0` looks like a
window-relative encoding (`0x10_0000_0000 | (va − K−0x17c0000) | 1`,
**inferred** from one sample), not a plain alias. Revisit if TA work
starts and faults or hangs.

**Most likely reason, and the change.** The queue never becomes valid
in the KSM. Your HwData+0x2730 = 1 tells the firmware that the host
installs queues, and the driver (`registration: Firmware`) does not.

*Try first:* **HwData+0x2730 = 0** (drop `(0x2730, 1)` from
`v27_2::HW_DATA_WORDS`). Then the 0xf install programs the descriptor
and valid bits itself (`0x1ad0c..0x1adfc`). Kick with the 25G83 form,
minus the descriptor item:
- items `[lead 5], 0xf, 0xe KickAnnounce{qid, count 1, ts}`;
- **no** gate bit 254 in the entry;
- or keep the gate and append the 0x10 after the 0xe.

0xe is what makes the firmware advance the queue's kick count
(`KSM+0x21018`); 0x10 alone never does. Check: after the first 0xf, sgx
`+0x21068` bit 34 should read 1.

*Second-best:* keep +0x2730 = 1, as macOS does, and install from the
host. Reuse `m5::queue::HardwareSubmission::new`/`advance_pair`:
- at registration: invalidate, then port tag/descriptor (the same value
  as `kick::ksm_slot_descriptor`), then valid high then low;
- per kick: port `tag+0x10` with 1.

The G16 port tag format is **unverified**. M5 uses `0x0020_0800_0002_1008
| qid<<44`; the older `RenderRegistration` uses `0x0000_0400_0002_1008 |
qid<<43`. So if this path is taken, check `+0x21068` after the
registration writes before kicking.

### 18.4 Completion, and the two submission modes

New device result. With HwData+0x2730 = 0 and items `[lead 5], 0xf,
0xe` (no gate), the work **runs**: TA and 3D start timestamps are
written 12 µs apart, and record +0x1c = producer. But nothing completes
toward the host: no stamps, +0x54/+0x68 stay 0, no events or 0x42.

**(1) The completion path.**
- **Interrupt.** `fn_363c8` reads `KSM+0x10a10` (status) & enable mask
  `[0x1211f0]` and latches it in `0x11eab8`.
  - The mask is set at `0x36310`: `0x0a00620038` (`0x0e00620038` when
    `[0x1202f4]` = 2). It is written to `KSM+0x10a08` at power-up
    (`fn_36988`, `0x36ba4`) and in `AGFHALMCWWaitForIdle~` (`0x6b3c`).
  - Bit 21 (`0x200000`) is the KSM completion source. The handler acks
    it at `KSM+0x211b0` (`0x600000`), reads `KSM+0x211b8`, and raises
    event bit `0x200000` in `0x11eb48` (`0x36608`).
- **Hardware completion rings.** These are HwData `+0x2740/+0x2760/
  +0x2780/+0x27a0`, each {VA +0, firmware VA +8, entries +0x10, entry
  size +0x14, index +0x18}. `fn_1710c` (power-up, called with (1,1,0)
  from `0x39470` and `0x3b834`) programs each one as `KSM+0x21148 +
  idx*8 = va&0x7ffffffffe0 | entries<<48 | 1` (`0x171c8..0x171e0`, …).
  Neither the interrupt nor the rings depend on +0x2730.
- **Drain.** `fn_38098` (event task, `0x38788`) calls `fn_1647c`.
  - For each ring listed in `0x5cad4`, it reads the count at
    `KSM+0x21168 + idx*8` (bits 31:16, `0x16b48`).
  - For each entry: `fn_13570` (parents check), then `fn_137d0`.
  - `fn_137d0` writes the stamps from the descriptor anchors (TA
    +0x8a6/+0x8ce/+0x8fe, 3D +0x2140/+0x2168/+0x2198, CL +0xf40/+0xf68),
    queue +0x54/+0x68, and builds the event records (type 1, then 0x42).
- **Where +0x2730 (`0x12034c`) enters:**
  - `0x1ac44`: 1 → 0xf install leaves the KSM to the host (§18.3).
  - `0x14518`: 1 → 3D completion links the pass's work node into the
    queue's job list itself: `fn_21014(dm, [rec+0x10], [desc+0x20],
    [desc+0x2168])`.
  - `0x16b84`: 1 → completion also drains the device-control ring
    (`fn_389c`).
  - `0x11710`, `0x395dc`: 1 → `KSM+0x211b0 = 0x4000000`.
  - `0xda88`, `0x39478`, `0x397c8`: 1 → enable interrupt line `0x10000`
    (`fn_48268`), set `KSM+0x10a08 = 0x200000` (completion source
    only) and `KSM+0x211b0 = 3`.
  - `0x3953c`, `0x39778`: power and idle decisions.

**The two modes:**
- **+0x2730 = 0 is the legacy mode.** There the work node is linked into
  the job list at **dispatch**, by the ring commands type 0/1/3 (TA
  `0x1a674`: `fn_21014(dm, [rec+0x10], [desc+0x10], [desc+0x8ce])`; 3D
  `0x1aa60` with `[desc+0x20]`, `[desc+0x2168]`; CL `0x1a978` with
  `[desc+0x10]`, `[desc+0xf68]`).
- **+0x2730 = 1 (macOS)**: no ring descriptor, and completion links the
  node instead.

Your run used legacy KSM handling but dropped the descriptor item. No
work node was ever linked into the job list, so completion finds no job
to retire and reports nothing. That explains the start timestamps
without stamps or events. (**Inferred** from the two `fn_21014` call
sites. That the job list is what completion retires from is consistent
with "job list empties" earlier.)

This corrects §18's "not acceptable" verdict on descriptors in the ring.
They are wrong only in macOS's mode (+0x2730 = 1). In legacy mode they
are required.

**(2) The host port (macOS mode).** No firmware code touches
`sgx+0x4090/0x4098`; `fn_1710c` restores the KSM with direct register
writes. So the port format cannot be taken from the firmware. What
both driver encodings do show:
- the tag's low bits are the target KSM register: `0x2_1008` = queue
  descriptor, the firmware's `+0x21008`;
- `tag+0x10` = `0x2_1018` = the kick-count register, which 0xe writes
  with its count (`0x1aa04`);
- the QID sits in a high field (`<<43` with bit 42 in
  `RenderRegistration`; `<<44` with bits 43 and 53 in M5).

So the port is an indirect "select qid, write KSM register" FIFO. Per
kick, the host writes `tag+0x10` with payload 1 (advance by one). The
0x10 command then clears the gate, as before. The G16 bit layout of the
tag is **unverified**.

The register-level equivalent is what the firmware does in legacy
mode:
- `sgx+0x103a8 = qid`;
- `sgx+0x21008 = descriptor`;
- valid `+0x21070`/`+0x21068`;
- per kick `+0x103a8 = qid`, `+0x21018 = 1`.

From the host this races with the firmware's own uses of the select
register (`fn_1710c` save/restore, `0x15fec`).

**Recommendation: (A), legacy mode.** It is the driver's original 25G83
protocol, and the firmware implements it end to end. Keep HwData+0x2730
= 0 and put the descriptor item back:

| Queue | Items |
|---|---|
| TA | `[lead 5], TaDescriptor VA (tag 0), QueueConfig, KickAnnounce(qid, count 1, ts)` |
| 3D | `FragmentDescriptor VA (tag 1), QueueConfig, KickAnnounce` |
| CL | `ComputeDescriptor VA (tag 3), QueueConfig, KickAnnounce` |

This is the `!m5` branch of `render/publication.rs`
(`push(descriptor)` before the config). No gate bit and no 0x10 are
needed (`KickPredecessor` only where 25G83 used it).

The firmware validates 0x9a0/0x2240/0x1040 bytes of the descriptors.
It reads the work node at +0x10 (TA, CL) or +0x20 (3D), 0xc8 bytes,
and the stamp pointers at +0x8ce/+0x2168/+0xf68. Those offsets are the
driver's 25G83 descriptor fields (§18.1).

**(B)** stays the macOS-exact option: +0x2730 = 1, host-port install
and per-kick advance, no ring descriptor. It needs the G16 port tag
format, which only a host-MMIO trace of macOS can give.
