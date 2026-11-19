# GPU device tree for T6040 (J614s): what drm/asahi expects

Phase 4 of `docs/gpu/plan.md`. A draft only: `t6040-gpu.dtsi.draft` is
not included anywhere, not wired into the kernel build, and not in
`kernel/patches/`.

Sources read (2026-11-14):

- Kernel: flake input `linux` = AsahiLinux/linux `6ba0637d1ed9`
  (`/nix/store/1kjh602cvf92cnhaa3nv5aiky5kq8iaq-source`):
  `drivers/gpu/drm/asahi/{driver.rs,gpu.rs,mmu.rs,regs.rs,hw/mod.rs,hw/t602x.rs}`,
  `Documentation/devicetree/bindings/gpu/apple,agx.yaml`,
  `arch/arm64/boot/dts/apple/{t602x-die0,t602x-common,t6020,t6021}.dtsi`.
  No M3 or M4 tree in it has a GPU node (t603x, t8122, t8132 leave it out).
- m1n1: `upstream/m1n1/src/kboot_gpu.c`, `src/kboot.c` (`dt_set_memory`),
  `src/firmware.{c,h}`, `rust/src/gpu/initdata.rs`.
- This machine: `nixos-m4pro gpu build/adt.bin`, `power-chain … /arm-io/sgx`
  and `/arm-io/gfx-asc`, the raw ADT (m1n1's `adt.py`), and the
  `gpu-probe` run in `build/agx/20261114-boot2/probe.txt`.
- Our tree: `kernel/patches/0001`, `0003`, `0008`, `0010`, `0013`, `0023`.

## How the driver gets its configuration

1. **Match.** The OF table in `driver.rs` matches only
   `apple,agx-t8103|t8112|t6000|t6001|t6002|t6020|t6021|t6022`. Each entry
   points to a static `HwConfig` in `hw/*.rs`. That holds most chip
   facts: generation and variant, cluster and die counts, `has_csafr`,
   the MMIO `io_mappings` that the firmware maps, sensor masks and SRAM
   constants. T6040 needs a new `hw/t6040.rs` and an
   `apple,agx-t6040` entry (phase 5).
2. **Firmware ABI.** `apple,firmware-compat` (3 cells, required) selects
   the `GpuManager` version. Only `(G13,12.3)`, `(G14G,12.4)`, `(G13,13.5)`,
   `(G14G,13.5)` and `(G14 other,13.5)` exist. Anything else gives
   `Unsupported GPU/firmware combination`, `ENODEV`.
3. **Dynamic config** (`gpu.rs make_dyncfg`, `hw/mod.rs PwrConfig::load`):
   the OPP tables, leakage and power-controller properties, and
   `apple,firmware-version` (optional, defaults to 0.0.0).
4. **Memory regions** (`mmu.rs`): `handoff` and `ttbs` are mapped by name.
   `pagetables` is taken as a physical base (kernel TTB1) and must be at
   least one UAT page.
5. **Calibration blobs**: `hw-cal-a`, `hw-cal-b` and `globals`, sized by
   `debug,*-size`. The kernel builds HwDataA/B and globals itself from the
   DT properties. It only **compares** its result against m1n1's blobs
   (`initdata.rs`) and falls back to an empty blob if they are missing.
   The blobs therefore help with checking but are not needed to boot.
6. **Not used by the driver**: interrupts (no IRQ is requested; the
   firmware talks through the mailbox), runtime PM (the single
   `power-domains` entry is attached by genpd and powered at probe), and
   any ADT region other than the three UAT ones.

## Property → source map

"m1n1" means `dt_set_gpu()` overwrites the value at boot from the ADT. In
the final tree only a placeholder is needed. "static" means the value
lives in the .dtsi. "unit" means the draft holds this J614s's ADT value
so that it is complete.

| DT property | Read by | Source for T6040 | Status |
|---|---|---|---|
| `compatible` | OF match | new `"apple,agx-t6040", "apple,agx-g16x", "apple,agx-g16s"` (pattern of t6020; ADT `gpu,t6040`; firmware `g16s`) | needs driver entry and binding; `g16x` is a guess |
| `reg` `asc` | `regs.rs start_cpu` (maps 0x4000) | ADT gfx-asc reg 0 = `0x28a600000` (+0x88000) | known |
| `reg` `sgx` | `regs.rs` (maps exactly 0x1000000) | ADT sgx reg 0 = `0x288000000` (+0x3758000) | known; G16 ID regs at +0xd04000 unverified |
| `interrupts` | none | ADT sgx: 1481 1482 1483 1484 1505 1507 1496 1498 | known, roles unknown |
| `mboxes` → `agx_mbox` | RTKit | gfx-asc reg 0 + 0x8000 = `0x28a608000`; ADT gfx-asc IRQs 1501–1504 | address matches the tracer's ASC mailbox; IRQ order assumed as on t602x |
| `power-domains` | genpd | `ps_gfx` (`pmgr_gfx`+0x110), parent `ps_afr` (+0x100); ADT gates 0x190/0x192 (sgx), 0x191 (gfx-asc) | **blocker**: patch 0008 removed these after afr power-on raised an SError |
| `memory-region` `ttbs` | `mmu.rs` | m1n1 ← ADT `gpu-region` `0x105fffb8000`+0x4000 | m1n1 C path ok |
| `memory-region` `pagetables` | `mmu.rs` | m1n1 ← ADT `gfx-shared-region` `0x105fff78000`+0x40000 | ok; note new `gfx-shared-l2-region` |
| `memory-region` `handoff` | `mmu.rs` | m1n1 ← ADT `gfx-handoff` `0x105fff70000`+0x4000 | ok; PPL handoff layout on 27.2 unknown |
| `memory-region` `hw-cal-a/b`, `globals` + `debug,*-size` | `gpu.rs` (compare only) | m1n1 Rust `rust_fill_gpu_initdata` | no G16 / 27.2 support in m1n1 Rust |
| `apple,firmware-compat` | `driver.rs` (required, 3 cells) | m1n1 ← `/chosen firmware-version` = `mBoot-20457.41.3` | **blocker**: not in m1n1's `fw_versions` table, so m1n1 writes `<0>` |
| `apple,firmware-version` | `gpu.rs` | m1n1, same source | as above |
| `apple,firmware-abi` | binding only | m1n1 | as above |
| `operating-points-v2` (16 OPPs: `opp-hz`, `opp-microvolt` ×2, `opp-microwatt`) | `PwrConfig::load_opp` | m1n1 ← ADT `perf-states` (2 tables × 16, ADT order) + `calc_power` max power | unit values in draft; `opp-microwatt` TODO |
| `apple,cs-opp`, `apple,afr-opp` (8 OPPs, 1 voltage each) | `load_opp` (has_csafr) | m1n1 ← ADT `cs-perf-states`, `afr-perf-states` (dies 1, count 8) | unit values in draft |
| `apple,core-leak-coef` (2), `apple,sram-leak-coef` (2) | `PwrConfig` (length = `max_num_clusters`) | m1n1 ← efuses (page `0x508374000` +0xc10..0xc2b, aura layout); per-unit values are not kept in the repo | placeholder; a single sram fuse may serve both clusters (check) |
| `apple,cs-leak-coef`, `apple,afr-leak-coef` (1 each) | `PwrConfig` (length = `num_dies`) | m1n1 ← efuses | placeholder |
| `apple,min-sram-microvolt` | required | static; ADT SRAM floor 810 mV | 810000 assumed (t602x: 790000) |
| `apple,csafr-min-sram-microvolt` | required (csafr) | static; ADT cs/afr `min_sram_volt` 810000 | 810000 assumed (t602x: 812000) |
| `apple,perf-base-pstate` | optional (1) | ADT has no `gpu-perf-base-pstate` | 1 |
| `apple,power-sample-period` | required | ADT sgx `gpu-power-sample-period` = 8 | known |
| `apple,pwr-sample-period-aic-clks` | optional | ADT `gpu-pwr-sample-period-aic-clks` = 200000 | known |
| `apple,avg-power-*`, `fast-die0-*`, `perf-*`, `ppm-*`, `pwr-*`, `se-*` | `PwrConfig` (many required) | not in the ADT; Asahi took them from macOS. Draft: t602x-die0 base with t6020.dtsi overrides | placeholders; decode the real ones from our 27.2 InitData traces |
| `apple,power-zones` | optional | none (t602x has none) | omitted |
| alias `gpu` | m1n1 | `aliases { gpu = &gpu; }` | needed |
| `/reserved-memory` `uat-*`, `hw-cal-*`, `globals` | m1n1 (`fdt_path_offset`) | placeholders as in t602x-common.dtsi; our `/reserved-memory` comes from patch 0023 | needed |

Notes on the ADT tables:

- `perf-state-count` = 16 (state 0 off), `perf-state-table-count` = 2.
  This matches T6020's two clusters, so `opp-microvolt` takes 2 cells. The
  frequency order is **not monotonic**: the ADT interleaves the two
  firmware ladders (perf maps A/B at SGX +0xe01400/+0xe01480). The driver
  indexes by position, so the draft keeps ADT order. `max_freq` and
  `max_power` are computed as maxima, so they are unaffected. The ADT also
  has `perf-states1` and `perf-states-sram1` (table 1 alone). m1n1 does
  not use these, because `perf-states` already holds both tables (32
  entries).
- `opp-microwatt` per state comes from m1n1 `calc_power_t600x`, which
  needs per-chip constants (`s_sram`, `k_sram`, `s_core`, `k_core`,
  `s_cs`, `k_cs`, `dk_*`, `imax`) and fuse locations. None exist for
  T6040. aurora's `dt_set_gpu_t6040` is the reference that `gpu_probe.ml`
  already follows for the fuses.
- Regions the driver does not take but that must stay out of Linux's RAM:
  `gfx-shared-l2-region` (`0x105fff74000`+0x4000), the firmware segments
  `__TEXT` `0x10000c1c000`+0x64000, `__DATA` (= `gfx-data`)
  `0x10001ccc000`+0xc4000 and `__DATA_SHARED_RO` `0x10001d90000`+0x8000.
  m1n1 only declares `phys_base..phys_base+mem_size` as usable, so these
  are probably excluded already. This should be confirmed against the
  m1n1 log ("Usable memory is …").

## What m1n1 `dt_set_gpu()` needs for T6040 / G16

As it stands, `dt_set_gpu()` prints `ADT: GPU: unsupported chip!` and
returns 0 for T6040, so it leaves the node untouched. To fill the node it
needs:

1. `chip_id` cases `T6040` (and `T6041`): `has_cs_afr = true`, `dies = 1`,
   and a `calc_power` for T6040. The T6020 constants are a starting point
   only. The fuses are at `0x508374000` +0xc10..0xc2b, not
   `0x29e2cc1f8…`. `get_core_counts` should read `+0xe01500..08`, the
   same as t602x, with 10 cores per cluster: `0x37b`, `0x3db` give 8+8 on
   this unit.
2. `downstream_dtb` must include `apple,agx-t6040`. Otherwise
   firmware-version and firmware-compat are not written.
3. A `V27_2` (`mBoot-20457.41.3` → `{27, 2, 0}`) entry in
   `firmware.{c,h}`.
4. Rust `chip_hwcfg()` (`0x6040`), `GpuGen::G16` and 27.2
   HwDataA/HwDataB/Globals layouts, needed for `rust_gpu_initdata_size`
   and `rust_fill_gpu_initdata`. Without them `dt_set_gpu` returns -1
   **after** writing the regions and OPPs, and the kboot error path
   aborts the boot. Either ship (1)–(3) with the Rust part skipped for
   T6040, or patch that failure to be non-fatal. The kernel does not
   need the blobs.
5. Optionally, `gpu-perf-base-pstate` (absent here, so 1).

Alternative while m1n1 lacks this: commit the unit values that are
already in the draft, so that only the three UAT regions and the firmware
version need m1n1. That is a smaller m1n1 patch, at the cost of
per-machine values in the tree.

## Blockers and unknowns

- **Driver**: no `apple,agx-t6040` match, no `HwConfig`, no G16 or 27.2
  `GpuManager`. The kernel-half UAT is `0xfffffc0000000000` and up on
  27.2, against the driver's `IOVA_KERN_BASE 0xffffffa000000000`. 27.2
  InitData, RegionB and command layouts differ (`docs/gpu/facts.md`).
  This is all phase 5.
- **Firmware version**: 27.2 (`mBoot-20457.41.3`) is unknown to m1n1.
  `apple,firmware-compat` would be `<0>`, and the 3-cell read fails.
- **m1n1 kboot**: no T6040 calibration (power constants, fuse layout),
  no G16 Rust initdata.
- **Power domains**: afr power-on SError (patch 0008) is unexplained.
  The ADT flags afr always-on, yet it is gated after boot, and SGX reads
  need afr up first.
- **Tunables**: the PID, filter and leakage-scaling values are
  placeholders. The real ones are in the macOS 27.2 InitData, which our
  traces can decode.
- **Unverified**: the mailbox IRQ order; the roles of the 8 sgx IRQs; the
  ID registers at +0xd04000 on G16; whether the firmware segments are
  outside usable RAM; the content and magic of the 27.2 handoff region;
  `min-sram-microvolt` (810 mV from the tables, not from macOS).
- **Binding**: `apple,agx.yaml` needs g16 compatibles and a fuller
  property list. Even for t602x the binding is behind the dts.

## Checking the draft

The draft builds as a fragment against a stub root using stock `dtc`,
once the float cells are replaced, since stock `dtc` lacks Asahi's float
support. Instructions below are from the run used here:

```
cpp -P -nostdinc -undef -x assembler-with-cpp -I $LINUX/include test.dts > out.dts
dtc -I dts -O dtb -o out.dtb out.dts
```

with `test.dts` defining `aic`, `soc`, `pmgr_gfx` and `reserved-memory`
and including the draft (floats sed'ed to `<1>`).
