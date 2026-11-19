# aura: handing the T6041 internal DCP to Linux under macOS 27.2

Goal: aura (stage 2, nixos-aurora's pin `5dcf62d`) should hand the running
internal display coprocessor (DCP) of the J614s over to Linux when stage 1 is
macOS 27.2. Today every 27.2 boot logs

    DCP: T6041: no qualified OS firmware for apple,t6041-dcp: nothing done

(`src/kboot_display_handoff.c:3759`), because the T6041 profile qualifies only
OS firmware 26.6.2. This note lists every check on that path, what 26.6.2 and
27.2 give each one, what aura publishes, and the patch plan. The kernel side
(`drivers/gpu/drm/apple/dcp.c`) is out of scope here; see "Kernel contract"
below for what it has to accept.

## Sources

- aura tree: the `5dcf62d` checkout (`aura-pinned` in the session scratchpad).
  Line numbers below are of that tree, file `src/kboot_display_handoff.c`
  unless another file is named.
- 26.6.2 values: aura's own profile and its host test
  (`tests/t6041_display_host.c`, `tests/python/test_t6041_display_handoff.py`).
  The test world is synthetic (made-up addresses, a made-up image UUID), so
  for 26.6.2 only the *shape* is known: 7 dcp segments (`__TEXT;__DATA;__OS_LOG`
  + 4 heap, carveouts 49/50/57/94/95/14), dart-dcp unlocked and dart-disp0
  locked by iBoot, two-level tables, display SID 0 mapping two heap segments
  (one is /vram), piodma SID 16 one.
- 27.2 values: `build/adt.bin` (captured 2026-11-13 under 27.2: `/chosen`
  `firmware-version` and `system-firmware-version` are `mBoot-20457.41.3`; the
  GPU's three segments in it are what the 27.2 GPU patch handles), and the
  aura boot log of the 2026-11-15 install
  (`local/boot-logs/20261115-aurora-install-ch1.log`: OS and system firmware
  27.2, chip 0x6040, J614s, boot-args RAM window, framebuffer). Raw 27.2
  addresses and the image UUID are in `local/unit-values.md` ("DCP (internal
  panel) in the 27.2 ADT"); below they are written by role.
- ADT reading: a 40-line Python ADT walker (scratch, not committed); the
  PMGR chain with `dune exec -- nixos-m4pro power-chain build/adt.bin /arm-io/dcp`.

The ADT and the boot log come from different boots (the ADT from a 2026-11-13
m1n1 boot, the log from 2026-11-15 aura boots). The carveout layout matched
where both show it (region-id-2 and region-id-4, the boot framebuffer at the
start of /vram), but per-boot addresses (`__OS_LOG` buffers, boot-args RAM
window) must be re-read on the boot that does the handoff. aura re-reads them
itself, so this only matters for the predictions below.

## How the T6041 path is entered

`kboot.c:8024`: root compatible `apple,t6040` calls
`dt_set_display_handoff()` (`:3726`). It is fail-soft (always returns 0) and
transactional (scratch DT copy, committed only when every step passed). The
display-power node is published separately by `dt_set_t6040_sleep_display()`
(`kboot.c:10356`, called at `kboot.c:11344`), which does not depend on the
handoff.

## 1. Every check, in order

"Pass (27.2)" means the 27.2 ADT/log value satisfies the check.
"Capture" means it depends on live register or page-table state that no file
here records.

### A. Gates in `dt_set_display_handoff()` (nothing is touched before these pass)

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| A1 | `:3730-3734` | FDT root `compatible` is in `dcp_socs[]`; `apple,t6040` selects `dcp_soc_t6041` (`:404`) | J616s/J614s DT | Pass: `apple,j614s`, `apple,t6040` |
| A2 | `:3751` | `chip_id == T6040` and the root is `apple,j616s` or `apple,j614s` (`board_gate`) | 0x6040 | Pass: log `Chip-ID: 0x6040`, `apple,j614s` |
| A3 | `:3757-3761` | `firmware_os_components() == soc->os_fw` (V26_6_2) and not V_UNKNOWN. `firmware_os_components()` (`firmware.c:262`) maps OS iBoot `mBoot-18000.161.10*` to 26.6.2, otherwise returns the detected version | `mBoot-18000.161.10` gives V26_6_2 | **FAIL**: `mBoot-20457.41.3` is V27_2 (`firmware.c:219`). This is today's log line |
| A4 | `:3763-3768`, `dcp6_dt_describes()` `:3221` | FDT aliases `dcp`/`disp0` resolve; compatibles `apple,t6041-dcp` / `apple,display-subsystem` | DT side | Pass: `t604x-j614-j616.dtsi:31-33`, `t604x.dtsi:397,659` (DT side, not version-dependent) |
| A5 | `:3770`, `dcp6_armed()` `:2430` | no `optin`, so always armed | armed | armed |

### B. `__OS_LOG` reservations (`dcp6_find_nubs()` `:849`, `dcp6_reserve_oslogs()` `:943`)

The nubs are every `/arm-io/{dcp,dcpext,dcpext0..7}/iop-*-nub` in the ADT
(`soc->nubs` is NULL). A failure here only skips that nub's reservation, but
B-checks on the panel nub are needed again in G4 (`dcp6_check_resv()`).

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| B1 | `:849-873` | which nubs exist | test: dcp (+dcpext0/1) | dcp, dcpext0, dcpext1. No dcpext2 (see the dcpext note at the end) |
| B2 | `:879-887` | nub present, `segment-ranges` a multiple of 32 bytes, at most 16 entries, `segment-names` present | 7 entries | Pass: 8 entries (dcp), 4 (each dcpext) |
| B3 | `:891-907` | exactly one segment with flags 0xa, named `__OS_LOG`, remap == phys | segment 2 | Pass: segment 2 in all three nubs, remap == phys |
| B4 | `:910-915`, `dcp6_dram()` `:617` | `/chosen` `dram-base`/`dram-size`; buffer nonzero, at most 1 MiB, 16K aligned, inside DRAM | 0x20000 | Pass: 0x25000 rounded to 0x28000 for each; DRAM 0x100_0000_0000 + 24 GiB |
| B5 | `:927-941` | buffer vs aura's loaded file part (`kboot_loaded_file_part()`): warns and marks `/chosen/asahi,aura-oslog-overlap`, never refuses | - | Capture (same-boot address). Not a refusal |
| B6 | `:957-967` | `/reserved-memory/dcp-oslog@<phys>` absent or identical | absent | Pass on a fresh DT |
| B7 | `:969-975` | no overlap with another nub's buffer | - | Pass: the three buffers are adjacent, not overlapping |
| B8 | `:976`, `dcp6_oslog_conflict()` `:726` | with `oslog_in_rsv`: a `/memreserve/` may contain the buffer whole, must not cut it; no enabled `/reserved-memory` node may overlap it | test `oslog-in-memreserve` | Pass on the ADT addresses: all three buffers lie wholly inside the CTRR_D `/memreserve/` aura adds before the display code (`kboot.c:815`, log `reserved M4+ SMP-RO CTRR_D`). Re-check on the handoff boot |
| B9 | `:977`, `dcp6_carveout_conflict()` `:752` | no overlap with the MCC carveouts (`mcc_carveouts[]`; on T6040 these are ADT region-id-4 and region-id-2, `mcc.c:263-298`) | - | Pass |

### C. Hardware state (`dcp6_check_hw()` `:1538`)

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| C1 | `:1545-1552` | ADT `/arm-io/dart-dcp` and `/arm-io/dart-disp0` compatible `dart,t8110`; `reg[0]` of `/arm-io/dcp`, `dart-dcp`, `dart-disp0` after the `/arm-io` ranges equal 0x402e00000, 0x402340000, 0x402300000 | same (profile constants) | Pass: 0x402e00000, 0x402340000, 0x402300000; both DARTs `dart,t8110` |
| C2 | `:1562-1564`, `dcp6_adt_power_on()` `:1473`, `dcp6_adt_ps()` `:1452` | ADT `/arm-io/dcp` `clock-gates` resolved through the ADT PMGR table to power-state registers; each read (guarded) must be on (actual = active, or target active + auto-enable) | test: virtual device over DISP_CPU | ADT part passes: `clock-gates` = 430 = `DISP-CPU-V` (virtual), parent 262 `DISP_CPU` at 0x502280000 + 0x10000 (chain DISP_SYS +0x258, DISP_FE +0x368). The register value: Capture (expected on: iBoot leaves the panel lit) |
| C3 | `:1574-1586` | guarded reads: ASC `CPU_CONTROL` (0x402e00044) RUN bit, `CPU_STATUS` (0x402e00048), `PROTECT` of dart-dcp (0x402340200) and dart-disp0 (0x402300200) | test: running, dart-dcp unlocked (0x1e0), dart-disp0 locked (0x1e1) | Capture. ADT `iop-dcp-nub` says `pre-loaded` 1, `running` 1 |
| C4 | `:1596-1615` | dart-dcp already locked, or the DCP running (then `lock_due`: locked only after every check, G6) | lock_due | Capture (follows C3) |

aura logs C2 and C3 on every boot (`display power state ...`,
`CPU_CONTROL ... PROTECT dart-dcp ... dart-disp0 ...`), so one boot of the
patched aura answers them.

### D. Firmware segments (`dcp6_dry_run()` `:2033`, `dcp6_get_segs()` `:1784`)

The T6041 profile has no fixed layout (`segs` NULL), so the layout is derived
from the ADT (`dcp6_derive_segs()` `:1669`).

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| D1 | `:1786-1803` | `iop-dcp-nub` present; `segment-ranges` 1..12 entries; `segment-names` present | 7 | Pass: 8 (`__TEXT;__DATA;__OS_LOG;unknown` x5) |
| D2 | `:1806-1811` | `/chosen` dram, `/chosen/carveout-memory-map` | present | Pass |
| D3 | `:1675-1676` | `/vram` `reg` | /vram = heap segment | Pass: /vram is segment 6 (0x57ac000 bytes) |
| D4 | `:1678-1721` | flags: one text (1), one data (0) named `__DATA`, one 0xa named `__OS_LOG`, others heap (2); one heap at /vram | 1,0,0xa,2,2,2,2 | Pass: 1,0,0xa,2,2,2,2,2 |
| D5 | `:1722-1726`, `dcp6_find_carveout()` `:1637` | every non-log segment equals exactly one `region-id-N` (base, 16K-rounded size) | 49,50,57,94,95,14 | Pass: 49, 50, 57, 94, 95, 14, 157 (the extra 16K heap segment 7 is region-id-157, the same id the fixed T6030 layout has) |
| D6 | `:1735-1736` | text, data, `__OS_LOG` and /vram all present | yes | Pass |
| D7 | `dcp6_get_vm()` `:1757` | profile window: both DARTs 0x100_0000_0000 + 0x10_0000_0000 | profile | Pass (profile constant; ADT agrees, see F2) |
| D8 | `:1837-1838` | segment flags match the derived layout | - | Pass (by construction) |
| D9 | `:1839-1842` | size nonzero, at most 256 MiB, 16K aligned, inside DRAM | - | Pass (largest is /vram, 0x57ac000) |
| D10 | `:1844-1846` | `__OS_LOG` remap == phys | - | Pass |
| D11 | `:1849-1853` | other remaps: inside dart-dcp's window, 16K aligned, same 1 TiB alias | - | Pass: all 7 DVAs within 0x9c0000..0x7f7c000 of the window |
| D12 | `:1855-1856` | non-log segments outside the RAM Linux gets (boot-args `phys_base` .. + `mem_size`) | - | Pass: `__TEXT` ends below `phys_base`; the rest start above the top of RAM (boot args of the 27.2 boots) |
| D13 | `:1857-1858` | no overlap with MCC carveouts (region-id-2/4) | - | Pass |
| D14 | `:1861-1866` | `region-id-N` base/size equal the segment | - | Pass |
| D15 | `:1869-1875` | no two segments overlap, physically or (non-log) in DVA space | - | Pass: physically disjoint; DVAs contiguous without overlap |
| D16 | `:1879-1883` | /vram == the framebuffer segment and the boot framebuffer (`cur_boot_args.video.base`) inside it | yes | Pass: log `fb init ... @<start of /vram>` |

### E. Page tables (`dcp6_walk()` `:1960`, `dcp6_walk_inner()` `:1919`, `dcp6_check_sid()` `:2000`), per stream: dcp = dart-dcp SID 23, display = dart-disp0 SID 0, piodma = dart-disp0 SID 16

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| E1 | `:1966-1969` | ADT `pt-region-<sid>` | present | Pass: `pt-region-23` (0x30000), `pt-region-0` (0x20000), `pt-region-16` (0x10000) |
| E2 | `:1970-1973` | ADT `vm-base`/`vm-size` equal the window | 0x100_0000_0000 / 0x10_0000_0000 | Pass: same on both DARTs |
| E3 | `:1979-1985` | pt-region: at most 1 MiB, 16K aligned, in DRAM, outside usable RAM, not in an MCC carveout | - | Pass |
| E4 | `:1925-1928` | `TCR(sid)`: TRANSLATE, no BYPASS_DART, no FOUR_LEVEL; `TTBR(sid)` valid | two-level | Capture. Registers: dart-dcp TCR 0x40234105c / TTBR 0x40234145c; dart-disp0 TCR 0x402301000, 0x402301040 / TTBR 0x402301400, 0x402301440. Expected two-level (36-bit window; the J616s bring-up read stream 23 TCR = 1 on 26.x), but the T6050 under 27.0 runs four-level roots, so this is the first thing to confirm |
| E5 | `:1930-1942` | L1 and every L2 inside the pt-region | - | Capture |
| E6 | `dcp6_run_add()` `:1899-1916` | every valid PTE points into a firmware segment; at most 16 contiguous runs per stream | - | Capture |
| E7 | `:2008-2020` | no stream maps `__OS_LOG`; display/piodma map only heap segments; each segment once, whole, from its base; dcp maps each at its ADT remap DVA | - | Capture |
| E8 | `:2023-2028` | dcp maps every non-log segment (now 7, including the new region-157 segment); display maps /vram | - | Capture |

### F. Handoff gates (`dcp6_handoff()` `:2464`)

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| F1 | `:3787` (in `dt_set_display_handoff`) | not J575C (`t6041_headless()` `:2967`) | - | Pass |
| F2 | `:2467-2470` | `dcp` node has no `apple,t6041-handoff` yet | absent | Pass |
| F3 | `dcp6_check_adt()` `:2239-2240` | `chip_id == soc->chip` | T6040 | Pass |
| F4 | `:2241-2242` | `firmware_os_components() == soc->os_fw` (second firmware gate) | V26_6_2 | **FAIL** (V27_2). Never reached today because A3 stops first |
| F5 | `:2244-2257` | `iop-dcp-nub` `uuid` is a well-formed UUID (`any_uuid`: not pinned) | any well-formed | Pass: well-formed (the 27.2 image UUID, see `local/unit-values.md`) |
| F6 | `:2259-2261` | `pre-loaded` == 1 and `running` == 1 | 1/1 | Pass: 1/1 |
| F7 | `:2263-2265` | C3/C4 results: MMIO ok, DCP running, dart-dcp locked or `lock_due`, dart-disp0 locked | yes | Capture |
| F8 | `:2266-2267` | D passed (`segs_ok`) | yes | Pass on the ADT |
| F9 | `:2268-2270` | E passed for all three streams | yes | Capture |

### G. Device tree side and publication

| # | Where | Reads | 26.6.2 | 27.2 |
|---|---|---|---|---|
| G1 | `dcp6_check_dt()` `:2153-2232` | board compatible; aliases `dcp`, `disp0`, `disp0-piodma`/`disp0_piodma`; compatibles; piodma child of dcp; parents with 2+2 cells; `/reserved-memory` 2+2; dcp and display `disabled`; `iommus` `<&dart-dcp 23>`, `<&dart-disp0 0>`, `<&dart-disp0 16>` (`dcp6_check_iommu()` `:2100`: t8110 DART, `#iommu-cells` 1, `reg` = 0x402340000 / 0x402300000, `apple,dma-range` = `<0x100 0 0x10 0>`, DART disabled); display and piodma share a DART, dcp another; mailbox disabled; none of `memory-region`, `memory-region-names`, `apple,t6041-handoff`, `apple,firmware-uuid` present yet | DT | Not version-dependent. The aurora `t604x.dtsi` (`:397-399`, `:639-681`) meets all of it, as it did for 26.6.2 |
| G2 | `dcp6_check_resv()` `:2441-2459` | the panel `__OS_LOG` node from B exists with a phandle and `apple,dcp-os-log`; no node yet for each other segment; no overlap with `/memreserve/` or enabled `/reserved-memory` | - | Pass on the ADT addresses if B8 passed. Neighbours checked: the ANE TEXT and AOP reservations end/start next to, not inside, the dcp `__TEXT` |
| G3 | `dcp6_publish()` `:2353-2428` | DT writes only (fails only if the DT is full) | - | - |
| G4 | `:2487-2491`, `dcp6_lock_now()` `:1618` | `lock_due`: re-read dart-dcp PROTECT, set TTBR_TCR lock | - | Capture |
| G5 | `dcp6_commit()` `:824` | scratch DT valid | - | - |

So on 27.2 only two checks are known to fail: **A3** (`:3757`) and **F4**
(`:2241`), both the firmware gate. Everything read from the ADT passes. The
live state (C2-C4, E4-E8, F7, F9, G4) has to be confirmed on hardware.

### What to capture for the "Capture" rows

The simplest capture is one boot of the patched aura (section 3). It is
fail-soft and logs the first failing check by name. Even if every check
passes, the stock kernel refuses `apple,t6041-dcp` with anything but 26.5.2 or
26.6.2 (`dcp.c` `dcp_check_firmware_version()`), so the panel stays on the
boot framebuffer. The release build logs C2/C3 and every refusal. A `DEBUG`
build of aura also logs the per-stream TCR/TTBR and the mapping summary
(`dlog_debug`, `:1519-1521`, `:2058-2066`), which is worth having once.

Read-only alternative from an m1n1 proxy on a 27.2 boot (stage 1 = m1n1 on
macostest): `read32` 0x502290000 (DISP_CPU state), 0x402e00044 (CPU_CONTROL),
0x402340200 and 0x402300200 (PROTECT), the TCR/TTBR pairs listed in E4. Then
walk the tables under each TTBR (L1 = `TTBR[29:2] << 14`, 2048 x 8-byte
entries; PTE address = `(pte & GENMASK(39,10)) << 4`) and compare the runs
with the segment table in `local/unit-values.md`. Also note the same-boot
`__OS_LOG` addresses (B5/B8) and boot-args `phys_base`/`mem_size`.

## 2. What aura publishes for the kernel

On a fully passing T6041 handoff (`dcp6_publish()` `:2353`), all in one DT
transaction:

| Item | Where | 26.6.2 | 27.2, unpatched code path | 27.2, with the patch below |
|---|---|---|---|---|
| `/reserved-memory/dcp-oslog@<phys>` (no-map, phandle, `apple,dcp-os-log`) for dcp and every dcpext nub | B, `:1000-1024` | dcp (+dcpext0/1) | dcp, dcpext0, dcpext1 | same |
| `/reserved-memory/<node>@<phys>` per non-log segment, no-map, `compatible = "apple,asc-mem"` (`"framebuffer"` for /vram), with `iommu-addresses = <&owner (alias \| dva) size>` for each stream that maps it | `:2368-2410` | dcp-text, dcp-data, dcp-seg3/4/5, framebuffer | dcp-text, dcp-data, dcp-seg3, dcp-seg4, dcp-seg5, framebuffer, dcp-seg7 | same |
| dcp `memory-region` / `memory-region-names` (ADT order) | `:2412` | asc-firmware, dcp_data, os_log, region57, region94, region95, framebuffer | adds region157 (8 entries) | same |
| display, piodma `memory-region` / `-names`: the heap segments SID 0 / SID 16 map | `:2413-2414` | (test) region94+framebuffer / region95 | Capture (E7) | same |
| `apple,t6041-handoff = <1>` on dcp, display, piodma (nodes stay `disabled`) | `dcp6_set_list()` `:2311` | yes | yes | same |
| dcp `apple,firmware-uuid` = ADT `iop-dcp-nub` uuid | `:2419` | the 26.6.2 image | the 27.2 image | same (pinned) |
| dcp `apple,firmware-version` = `fw_versions[firmware_os_components()]` | `:2422`, `dcp6_fw_release()` `:1356` | `<26 6 2>` | `<27 2 0>` | `<27 2 0>` |
| dcp `apple,firmware-compat` | `:2425` | `<26 6 2>` | `<27 2 0>` | `<27 0 0>` |
| dart-dcp `PROTECT` TTBR_TCR lock (hardware, not DT), only after every check | `:2487`, `:1524` | set by aura | same | same |
| dart-disp0 | read only; must already be locked by iBoot | - | - | - |
| `apple,display-power` phandle on dcp + `display-power@5048a9c14` (`apple,t6041-display-power`, `reg` pmc-dcp 0x5048a9c14+0x8, ps 0x502280000+0x14000) | `kboot.c:10356` (separate, every boot) | yes | already published on 27.2 (log: `Published DCP apple,display-power`) | unchanged |
| dcpext firmware memory (`t6041_ext_handoffs()` `:3176`, `t6041_ext_fill()` `:2974`), only after the panel marker: fills the disabled DT placeholders of `/dcp@3a2e00000`, `/dcp@602e00000`, `/dcp@606e00000` from their ADT nubs; sets their `apple,firmware-version`/`-compat` | `:3132-3133` | as panel | `<27 2 0>` / `<27 2 0>` | `<27 2 0>` / `<27 0 0>` |

Nothing is enabled by aura on this path: the kernel's display gate enables
the nodes when it sees the marker.

## 3. Patch plan (aura, as a nix-config patch)

File: `~/nix-config/modules/j614s/aura-patches/0002-kboot_display_handoff-T6041-27.2.patch`,
next to the GPU patch, in the same style (`From: nix-config`, one-paragraph
rationale). Not applied anywhere yet; the patch was built and its host test run
in a scratch copy only (see "Test" below). The edits:

1. **`struct dcp_soc`** (after `os_fw_name`, `:256`): a second qualified
   firmware, the image pinned for it, and the release published as compat:

   ```c
       /*
        * A second qualified OS firmware (V_UNKNOWN: none), the DCP image pinned for it (its iBoot
        * version alone may not tell point releases apart, as 27.0's does not) and the release
        * published as apple,firmware-compat for it: the kernel interface that drives it.
        */
       u32 os_fw2;
       const char *os_fw2_name, *os_fw2_uuid;
       u32 os_fw2_compat;
   ```

2. **`dcp_soc_t6041`** (`:404`, J616s/J614s only; the M4 Max record
   `dcp_soc_t6041_max` is left alone, no 27.2 data for it), after `.os_fw_name`:

   ```c
       .os_fw2 = V27_2,
       .os_fw2_name = "27.2",
       .os_fw2_uuid = "71F140DC-F18D-31B3-9772-537A5CC8400D",
       .os_fw2_compat = V27_0,
   ```

   and update the record's comment (`:394-400`) to say 27.2 is qualified with
   the pinned image. The UUID is the firmware build's (the same on every Mac
   running that image, like `T6050_DCP_UUID`), not a per-unit value. Pinning it
   keeps a later 27.2.x that keeps the iBoot string but changes the DCP image
   from being handed over unchecked.

3. **Helpers** after `dcp6_fw_release()` (`:1359`):

   ```c
   /* The OS firmware is one the SoC's handoff is qualified for */
   static bool dcp6_os_fw_ok(void)
   {
       u32 v = firmware_os_components();
       return v != V_UNKNOWN && (v == dcp6.soc->os_fw || (dcp6.soc->os_fw2 && v == dcp6.soc->os_fw2));
   }

   static bool dcp6_os_fw2(void)
   {
       return dcp6.soc->os_fw2 && firmware_os_components() == dcp6.soc->os_fw2;
   }

   /*
    * apple,firmware-compat: the release whose kernel interface drives the firmware. The release
    * itself, except for os_fw2 (T6041 on 27.2: <27 0 0>, the kernel's firmware-27 interface).
    */
   static const struct fw_version_info *dcp6_fw_compat(void)
   {
       if (dcp6_os_fw2() && dcp6.soc->os_fw2_compat)
           return &fw_versions[dcp6.soc->os_fw2_compat];
       return dcp6_fw_release();
   }
   ```

4. **Gate A3** (`:3757-3758`):
   `if (!dcp6.soc->optin && !dcp6_os_fw_ok()) {` (same log line on refusal).

5. **Gate F4** (`:2241-2242`):

   ```c
       if (!dcp6_os_fw_ok())
           bail("OS firmware %s is not %s%s%s\n", os_firmware.string, soc->os_fw_name,
                soc->os_fw2 ? " or " : "", soc->os_fw2 ? soc->os_fw2_name : "");
   ```

6. **Image pin** in `dcp6_check_adt()`, right after the uuid checks (before
   `memcpy(dcp6.uuid, ...)`, `:2258`):

   ```c
       if (dcp6_os_fw2() && soc->os_fw2_uuid && strcmp(uuid, soc->os_fw2_uuid))
           bail("%s dcp firmware is not image %s\n", soc->os_fw2_name, soc->os_fw2_uuid);
   ```

7. **Compat publication**: `dcp6_fw_release()` becomes `dcp6_fw_compat()` in
   the two T6041 `apple,firmware-compat` writes, `:2425` (panel) and `:3133`
   (dcpext). `apple,firmware-version` stays `dcp6_fw_release()` (`<27 2 0>`,
   the truth). The T6030 dcpext write at `:2708` needs no change.

8. **Tests** (`tests/`):
   - `t8122_display_host/firmware.h`: add `V27_2 = 105` to the host enum.
   - `t6041_display_host.c`: size `fw_versions` to `V27_2 + 1` with
     `[V27_0] = {V27_0, "27.0", {27, 0, 0}, 3, "mBoot-20457.1.29"}` and
     `[V27_2] = {V27_2, "27.2", {27, 2, 0}, 3, "mBoot-20457.41.3"}`; make the
     firmware assertions in `contract_check()` (`:870-875`) compare against
     per-scenario `want_uuid`/`want_version`/`want_compat` (default the 26.6.2
     values); add scenarios `os-27-2` (PUBLISH: pinned uuid, version
     `<27 2 0>`, compat `<27 0 0>`), `os-27-2-other-image` (REFUSE) and
     `os-27-0` (NOTHING).
   - `python/test_t6041_display_handoff.py`: `REASONS` entries
     `"os-27-2": PUBLISHED`,
     `"os-27-2-other-image": "27.2 dcp firmware is not image 71F140DC-..."`,
     `"os-27-0": "no qualified OS firmware for apple,t6041-dcp: nothing done"`.
   - `test_unknown_profile_does_not_match_unknown_firmware` still works: it
     rewrites `.os_fw = V26_6_2,` in the record and `dcp6_os_fw_ok()` never
     matches V_UNKNOWN.

The full diff (223 lines, against `5dcf62d`) is
`dcp272/work/patch/0002-kboot_display_handoff-T6041-27.2.patch` in the session
scratchpad. It has no `From:`/`Subject:` header yet.

### Test

Built the T6041 host harness (`tests/t6041_display_host.c` + the real
`kboot_display_handoff.c` + libfdt, ASan/UBSan, the command line of
`build_host()` in the Python test) for both the pinned tree and the patched one,
and ran every scenario: pinned tree 52/52 pass, patched tree 55/55 pass
(the 52 plus `os-27-2`, `os-27-2-other-image`, `os-27-0`). The ASan/UBSan
build of the harness hangs on this Mac (even `list`), so this run was
without sanitizers, and pytest is not installed here, so the Python wrapper
was not run; its new `REASONS` strings match the logged lines. In
`os-27-2` the synthetic 26.6.2-shaped world publishes `firmware-version
<27 2 0>`, `firmware-compat <27 0 0>` and the pinned uuid; with another
image it logs `27.2 dcp firmware is not image 71F140DC-...` and publishes
nothing. One leftover: the `dlog_debug` line at `:2254` still says the image
is "not pinned here" on 27.2. Cosmetic (DEBUG builds only), worth rewording
in the final patch.

### Kernel contract (for the kernel-side change)

With the patch, a 27.2 J614s dcp node carries
`apple,firmware-version = <27 2 0>` ("27.2.0"),
`apple,firmware-compat = <27 0 0>` ("27.0.0"), `apple,firmware-uuid` = the
27.2 image, `apple,t6041-handoff = <1>`, and the T6041 memory contract
(`memory-region` + `iommu-addresses` from the live two-level tables, nodes
disabled). The kernel's T6041 branch in `dcp_check_firmware_version()`
currently requires version == compat and 26.5.2/26.6.2, and returns
`DCP_FIRMWARE_UNKNOWN` otherwise. It needs: `apple,t6041-dcp` with compat
"27.0.0" and version "27.2.0" maps to `DCP_FIRMWARE_V_27_0` (the token the
T6050 and T8142 paths already use). Two things to check on the kernel side:

- The T6050 27.0 handoff gives the kernel a different contract (aura
  `t6050_publish()`: no `iommu-addresses`, four-level DARTs adopted live,
  nodes enabled by aura, `asahi,t6050-dcp-handoff`). The V27_0 code path must
  work with the T6041 contract above, and the T6041 enable gate keyed on
  `apple,t6041-handoff` must not be limited to `DCP_FIRMWARE_V_26_6_DESKTOP`.
- The dcpext nodes get the same version/compat pair; the kernel decides
  separately whether its dcpext code accepts it (they stay disabled
  otherwise).

Alternative, if the kernel side prefers it: publish `<27 2 0>` for both (drop
edit 7 and `os_fw2_compat`) and map "27.2.0" in the kernel. The plan above
follows aura's existing convention (`kboot.c` `dt_set_dcp_firmware()`: the
version is the release, the compat names the interface, e.g. 13.6.1 to 13.5).

## Side findings

- **dcpext on 27.2 J614s.** The 27.2 ADT has `/arm-io/dcpext0`
  (0x3a2e00000) and `/arm-io/dcpext1` (0x602e00000), both preloaded and
  running and sharing the panel `__TEXT`, and **no** `dcpext2`. aura's
  `t6041_exts` comment (`:2950-2953`) and aurora's
  `t6040-j614s-extdisp-hdmi.dtsi` assume the opposite (no dcpext0, HDMI on
  dcpext2 at 0x606e00000). After the panel handoff, `t6041_ext_fill()` will
  therefore refuse `dcpext2` ("firmware memory refused; placeholder remains
  disabled") and fill dcpext0/dcpext1 if the DT has their nodes
  (`t604x-extdisp.dtsi`, included by `t604x-j614-j616.dtsi`). The HDMI routing
  in the J614s DT needs another look under 27.2. This does not affect the
  internal panel.
- The 27.2 dcp layout is 8 segments, one more than the T6041 test world: a 16K
  heap segment, region-id-157 (the T6030 fixed layout has the same id). The
  derived layout handles it; the dcp stream must also map it (E8).
- The three `__OS_LOG` buffers lie inside the CTRR_D `/memreserve/` on the
  27.2 boots. `oslog_in_rsv` covers that (B8), but it depends on the
  same-boot addresses.
