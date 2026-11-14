# M4 Pro GPU on Linux: survey (2026-11-14)

What it takes to drive the J614s GPU (AGX G16S, `gpu,t6040`, 16 cores,
firmware from the macOS 27.2 stub) from Linux, kernel and userspace, and
how frames could reach the screen. Companion to [../plan.md](../plan.md)
(phases 5 and 6), [../facts.md](../facts.md) and
[../firmware-decode.md](../firmware-decode.md).

Sources read (shallow clones, 2026-11-14):

| Tree | Commit | Path |
|---|---|---|
| AsahiLinux/linux `asahi` (our kernel input) | `6ba0637d` (2026-11-05) | `drivers/gpu/drm/asahi`, `rust/macros/versions.rs` |
| aurora-silicon/linux `integration/aurora` (default) | `d89d8c0c` (2026-11-14) | `drivers/gpu/drm/asahi` |
| mesa/mesa `main` | `767fbf7c` (2026-11-14) | `src/asahi` |
| aurora-silicon/mesa `aurora-wip` (default) | `b6c070c5` (2026-11-14) | `src/asahi` |

**Main finding.** Upstream Asahi is the wrong base for 27.2. Its newest
interface is macOS 13.5 for G13/G14. aurora-silicon's fork of the same
driver already runs the M4 Pro (T6040) on macOS 26.6.2 firmware (25G83).
Its structures match almost every 27.2 change we found by tracing and
static decoding (details in A.3). Our 27.2 interface word differs from
aurora's only in the high half-word (`0x0c8a` → `0x0c8b`), so 27.2 is the
next revision of aurora's interface, not a jump from 13.x. Phase 5 becomes
"add a 27.2 variant to aurora's T6040 path", not "port drm/asahi from 13.5".

---

## A. Kernel (phase 5)

### A.1 How upstream drm/asahi handles firmware versions

- **`#[versions(AGX)]`** (`rust/macros/versions.rs`) is a proc-macro that
  stamps out one copy of every annotated struct, impl and const per
  supported (generation, firmware) pair. `AGX_VERSIONS` lists the axes:
  - generations `G13, G14, G14X`
  - firmware `V12_3, V12_4, V13_0B4, V13_2, V13_3, V13_5`
  - the five combinations actually built: `(G13,V12_3)`, `(G14,V12_4)`,
    `(G13,V13_5)`, `(G14,V13_5)`, `(G14X,V13_5)`

  Generated names carry the suffix, for example `GpuManagerG14XV13_5`.
- **`#[ver(V >= V13_5)]`, `#[ver(G >= G14X)]`** on fields, statements and
  match arms include or drop them per copy. Struct layouts in
  `fw/initdata.rs`, `fw/channels.rs`, `fw/workqueue.rs`, `fw/fragment.rs`
  and others are written once with these gates. Field offsets are not
  checked at build time beyond a few `static_assert!`s.
- **`hw/*.rs`** (`t8103`, `t8112`, `t600x`, `t602x`) hold one `HwConfig`
  per chip. A `HwConfig` covers the chip and its generation and variant,
  the UAT address sizes, core and cluster counts, perf-state and power
  coefficients, `sram_k`, the shared-region layout, and the `io_mappings`
  (`IOMapping` per slot) that become `HwDataB.io_mappings`. Per-unit
  calibration comes from DT properties that m1n1 fills (`kboot_gpu.c`).
- **Dispatch** happens in `driver.rs::probe`. The OF table maps
  `apple,agx-t8103/t8112/t6000-2/t6020-2` to a `HwConfig`. The driver then
  reads the DT property `apple,firmware-compat` (3 u32) and matches
  `(gpu_gen, variant, compat)` to the right `GpuManager*` monomorph. Any
  other combination fails with "Unsupported GPU/firmware combination".
- **Support today:** only G13 (M1 family) and G14 (M2 family; `G14X` =
  M2 Pro/Max/Ultra multi-cluster), on firmware 12.3, 12.4 and 13.5.
  `GpuGen` has only `G13 = 13, G14 = 14`, and `GpuCore` stops at `G14D`.
  There is nothing for G15 (M3), G16 (M4) or G17 (M5). The Asahi M4 feature
  page lists the GPU for T604x as **TBA**
  ([asahilinux.org/docs/platform/feature-support/m4](https://asahilinux.org/docs/platform/feature-support/m4/)).

The `versions` macro scales poorly to the 27.x interface. Each new version
multiplies every gated struct, and the 27.x object model differs in places
(queue registration, kick records, status blocks), not only in field
offsets.

### A.2 aurora-silicon's driver (the realistic base)

aurora-silicon/linux keeps the `drivers/gpu/drm/asahi` name but has grown
it to about 218k lines, licensed `GPL-2.0-only OR MIT` (same as Asahi). It
has its own per-generation trees (`g15/`, `g16/`, `g17/`, `g18/`, `m3/`,
`m5/`) and per-chip files including **`hw/t6040.rs`**, `t604x.rs`, `t6041.rs`,
`t6050.rs`, `t8132` (in `g16/`) and `t8140`.

- **Firmware identity** (`fwid.rs`) works like our plan's `agx fw-id`. It
  takes the SHA-256 of the loaded `__TEXT` with the 8 entropy bytes of the
  `GKTS` and `ECAP` records zeroed, plus other boot-filled ranges, checked
  together with the TEXT and DATA sizes. An unknown build is refused.
  **This also answers an open item in facts.md**: the `__TEXT` bytes that
  iBoot changes on every boot are those entropy records.
- **Firmware variants** (`g17/fw/variant.rs`). For builds that share an
  interface version, a small `Variant` struct records the differences: init
  graph, init ack (message or status word), queue-pointer offsets,
  queue-registration mode, `qid_floor`, and feature flags (mcache,
  ray traversal, lead commands, ...). Each SoC's `Config` lists the
  accepted `Build`s, each with an `os_version`, image hashes and a variant.
  This is close to what our `.sexp` schema plan wants.
- **T6040 today** (`hw/t6040.rs`):
  - runs on the `g17` code path with `Variant::V25G83`, accepting only
    **macOS 26.6.2 (25G83)** images (TEXT `0x60000`; ours is `0x64000`)
  - `gpu_generation: G16`, variant `S`, `usc_generation 3`,
    `hal_generation 200`, UAT 42/42 bits, 25 register windows
  - core layout measured on the **20-core** M4 Pro. **Our 2×8 (16-core)
    configuration is the explicitly "experimental"
    `alternate_core_masks: Some((10, 8))`**.
- **27.x elsewhere:** aurora accepts macOS **27.0 (26A428)** firmware for
  M5/A18 Pro (`t6050.rs`, `t8142.rs`, `V26A428`, `V26A428_M5`). It does not
  accept 27.2, and does not accept any 27.x on T6040.
- Caveat: Phoronix describes the project as a large, fast-moving fork
  outside upstream, largely AI-assisted
  ([Phoronix: Borealis](https://www.phoronix.com/news/Borealis-Vulkan-Driver)).
  Treat its comments as hypotheses and check them against our traces.

### A.3 Our 27.2 findings against aurora's 25G83 (T6040) layouts

| Our 27.2 finding | aurora 25G83 / g17 equivalent | Delta to port |
|---|---|---|
| InitData+0 fingerprint `0x0c8b6339839804c0` | `INTERFACE_VERSION = [0x04c0, 0x0396, 0xa322, 0x0c8a]` (`0x0c8aa322039604c0`) | Constant; same family, high word +1 |
| `host_mapped_fw_allocations` at +0x2c, must be 1 | `Root.unk_2c` "Required: 1" | None (aurora already has it) |
| Four new pointers +0xa8..+0xc7; firmware copies 0xc8 bytes | `Root` is 0xb8: `status_a_va` +0xa8, `status_b_va` +0xb0 | Two new pointers at +0xb8 and +0xc0 (one of them zero under macOS); Root grows to 0xc8 |
| "RegionB" at +0x18 with HwDataB at +0 | `Root.main_config_va` +0x18 → `MainConfig` | Naming only; our "RegionB" is aurora's MainConfig |
| HwDataB 0x2850, `io_mappings` at +0x640, **60** × 0x28 | `HwData25G83`: `register_map` +0x640, **53** × 0x28 (`RegisterMapEntry`: phys, va, total, element, unk_18, unk_20) | 7 more slots, so everything after shifts by 0x118. `chip_id` moves 0xe90 → 0xfb0, and our table maps directly onto `REGISTER_WINDOWS` |
| 16 voltage columns, main and alt DVFS curves, `pstate_map[2][16]` | `perf_a` +0xfc4, `perf_b` +0x1cd8, `perf_b_freq_mhz`, `cs_perf`, `afr_perf` (`AuxPerfTable` 0x148); board `main`/`auxiliary` pstate lists (`g16/board/data.rs`) | aurora already models two curves, and its J604 lists are the same as ours. Re-offset only. |
| `hw_rings[4]` (0x20 each) at +0x2740 | `CompletionRingDescriptor` 0x20 at `COMPLETION_DESCRIPTORS` 0x2620 | Same struct, moved |
| Queue ring entry 0x18 (RunCmdQueueMsg-like) | `WorkSlot` 0x18 and `KickAnnounce` 0x18 | Check field order against traces |
| Command queue 0x80 | `PointerBlock` 0x80 (`producer` +0x50 in V25G83) | Check offsets; possibly identical |
| Work types 0xf (0xc0 bytes), 0x10 | `CommandTag::QueueConfig = 0x0f` (`QueueConfig` 0xc0), `KickPredecessor = 0x10` (0x12) | Same tags; check layouts |
| 12 queue channels + DevCtrl, 0x20 records | `WORK_CHANNELS 12`, `CONTROL_CHANNEL 12`, `EVENT 13`, `TRACE 14`, `CHANNELS 17`, `ChannelEntry` 0x20, `ChannelState` 0x40 | Likely the same |

### A.4 What a T6040 + 27.2 port needs, with effort

Effort assumes one person who already has our trace and decode tooling,
and aurora as the base. Upstream-Asahi-only figures are in parentheses for
comparison.

| # | Work item | Effort |
|---|---|---|
| K1 | Kernel tree: build aurora's `drivers/gpu/drm/asahi` (plus the rust/macros and DT bits it needs) against our Asahi kernel input, or switch the kernel input to aurora's tree for a GPU generation only | 2–5 days (rebasing a 218k-line driver onto a moving Asahi tree is the main risk) |
| K2 | `fwid`: a 27.2 `Build` for T6040 (TEXT 0x64000, DATA 0xc4000, entropy record offsets found in our dumps, SHA-256) | 1 day |
| K3 | Variant `V27_2` in `g17/fw/variant.rs` plus `INTERFACE_VERSION` per variant (now a single const) | 1–2 days |
| K4 | Root 0xb8 → 0xc8: two new pointers; name and allocate the objects behind +0xb8 (perf block read by `fn_2ff18`) and +0xc0 | 3–5 days (the decode work is still open) |
| K5 | `HwData27_2`: re-offset 25G83's struct (53 → 60 register slots, then the shifted tail); fill the 60-slot `REGISTER_WINDOWS` for T6040 from our snapshot (25 live slots, slot 0x11 = SGX); `static_assert!` every anchor from `lib/agx/hwdata.ml` | 1 week. Our OCaml schema can generate it (plan tool 6). |
| K6 | DVFS: map our 16-column/alt-curve findings onto aurora's `PerfConfig`/`PerfGroup`; J614s board pstate lists; f32 `rel_max_powers`/`rel_boost_freqs` | 3–5 days |
| K7 | Queues and work: check `WorkSlot`, `PointerBlock`, `QueueConfig`, `KickPredecessor` and channel layouts against our 27.2 traces; adjust the variant flags | 1–2 weeks |
| K8 | 16-core T6040: aurora's `alternate_core_masks (10,8)` path, compute/render buffers sized for 2×8, core mask `0x37b`/`0x3db` | 1 week, hardware-risky |
| K9 | DT: GPU node with `apple,agx-t6040`, calibration (our `agx calib`), the reserved regions, firmware-compat. aurora's `aura` loader (`dt_set_gpu_t6040`) is the reference. | 3–5 days |
| K10 | Stabilisation: recovery, power-off/on, sleep (aurora flags `sleep_restart` as unknown for M4 Pro) | open-ended, weeks |

**Total, aurora-based: about 6–10 weeks** to a module that boots the 27.2
firmware and runs Mesa work on the 16-core part.
(Upstream-Asahi-based: `GpuGen::G16`, `V27_2`, a new `hw/t6040.rs`, and
re-gating InitData, HwDataA/B, channels, queues and every work command.
The kick and queue model is not 13.x's. Estimate 4–6 months, mostly
redoing what aurora has.)

Alternative short path: run the **26.6.2 firmware** that aurora already
supports, by putting a 26.6.2 macOS stub on the volume iBoot loads GPU
firmware from. This removes K2–K7 and leaves the 16-core work (K8) and the
DT (K9). It conflicts with the project goal (27.2, "next firmware is a data
change"), but is the quickest way to get a known-good reference trace and
driver on this exact machine.

---

## B. Userspace (phase 6)

### B.1 Upstream Mesa (`src/asahi`)

- Generations: **G13 and G14 only.** In `lib/agx_device.c`,
  `gpu_generation >= 13` is asserted and the only branches are 13 and 14
  (14X = multi-cluster). `lib/decode.c` and the drm-shim know 13 and 14.
  ISA description: `isa/AGX2.xml`. There is no G15/G16 code: grepping for
  G15/G16 finds only format names such as `R16G16`.
- Drivers: Gallium `asahi` (GL 4.6 / ES 3.2 conformant) and Vulkan `hk`
  (Honeykrisp). Both use the upstream `drm/asahi` UAPI.
- Asahi's own M3 status: M3 machines are officially supported since
  September 2026, but "the only major exceptions remain full DCP support
  and the GPU ... Do not expect performant or power-efficient 3D
  acceleration right now"
  ([Asahi, 2026-09](https://asahilinux.org/2026/09/m2-episode-1/);
  [Phoronix](https://phoronix.com/news/Asahi-Linux-Official-M3)). A
  secondary summary of the 7.3 progress report mentions M3 GPU RE reaching
  a triangle from m1n1. I could not confirm this from a primary source
  ([braindetox summary](https://braindetox.kr/ja/posts/asahi_linux_progress_report_linux_7_3.html)).
  The M4 GPU is "TBA" on Asahi's M4 page.

### B.2 Public ISA documentation for M3/M4

- **dougallj/applegpu** ([docs](https://dougallj.github.io/applegpu/docs.html))
  is still G13 (M1). Its 2025–2026 commits are G13 refinements
  (fmadd rounding, docs); there is no G15/G16 material.
- No Asahi blog post documents the G15/G16 ISA. Apple's public material on
  M3 (Dynamic Caching, hardware ray tracing, mesh shading) is
  marketing-level
  ([AppleInsider](https://appleinsider.com/articles/23/11/10/what-apples-three-gpu-enhancements-in-a17-pro-and-m3-actually-do);
  [Apple tech talk](https://developer.apple.com/videos/play/tech-talks/111375/)).
- **The de facto documentation is aurora's Mesa fork**
  (`aurora-silicon/mesa`, branch `aurora-wip`). Its `src/asahi/isa/AGX3b.xml`
  (about 4.7k lines) describes "Apple G15 (M3) / G16 (M4) native GPU
  instruction set" for `applegpu_g15s, g15d, g16g, g16p, g16s, g17p`.
  `AGX3c.xml` covers G17 (M5) and `AGX3d.xml` G18. `isa/README-metal-witness.md`
  shows how they ground encodings: compile MSL with Apple's own
  `metal-nt -archs applegpu_g17p` and decode the result. This is also a
  method we can use: Apple's toolchain on our macOS stub can emit G16
  machine code directly.

### B.3 What G16 needs on top of upstream Mesa

From aurora's tree, where these already exist as code:

- **A new ISA (AGX3b):** a new encoding and a new backend
  (`compiler/agx3_*`: isel, staging, scheduling waits
  `agx_insert_waits.c`, register-cache optimisation, packing). It is not a
  small delta to AGX2. aurora treats G16G and G17P as one compiler target
  "unless native code ... proves a difference".
- **Register file / Dynamic Caching:** occupancy is no longer fixed by the
  static register count the way G13 is (`agx3_static_spill_core`, staging
  and register-cache passes). This has to be modelled in register
  allocation and in the program descriptors.
- **Mesh shaders** (`agx3_mesh_core`, `agx_nir_gen1_mesh.c`) and
  **hardware ray tracing** (`agx3_rt_*`, ray-query lowering). These are
  optional for a desktop; GL and Vulkan 1.x work without them.
- **Command stream:** `genxml/agx3_cmdstream.h`, plus new descriptor and
  EOT formats (`agx3_*_eot.h`).
- **Chip identity:** in aurora's Mesa, **T6040 runs under
  `AGX_CHIP_G17P`**, detected by `chip_id 0x6040, gpu_generation 16,
  variant 'S'` (`agx_is_m4_pro()` in `lib/agx_device.h`). The M4 Pro is
  driven as a G17P-class device, matching the kernel side (A.2).
- **UAPI:** aurora extends `drm/asahi`'s UAPI (HAL generation, USC
  generation). Its Mesa and kernel must be taken as a matched pair.

Other projects:

- **aurora-silicon** ([GitHub org](https://github.com/aurora-silicon)) is the
  only public M3/M4/M5 GPU stack: kernel driver, Mesa, `aura` loader
  (m1n1 fork), and `nixos-aurora` (NixOS modules for its hardware stack,
  worth reading for packaging). Its Vulkan driver "Borealis" is
  Honeykrisp-derived and claims M1–M5 and A18 Pro
  ([Phoronix, 2026-10](https://www.phoronix.com/news/Borealis-Vulkan-Driver)).
  It is not in upstream Mesa.
- **Gravity Linux** reportedly has an early alpha on the base M4 Mac mini
  with display and a GPU driver but no Vulkan
  ([ModelFit, 2026-09](https://modelfit.io/blog/gravity-linux-m4-mac-mini-local-llm/)).
  I could not verify this.
- KosmicKrisp (LunarG) is Vulkan-on-Metal for macOS. It does not apply to Linux.

### B.4 Userspace effort

| # | Work item | Effort |
|---|---|---|
| U1 | Build aurora's Mesa (`aurora-wip`) as a Nix package matched to the kernel (K1) | 2–3 days |
| U2 | 16-core T6040 on 27.2: whatever `agx_is_m4_pro()` gates need for a 2×8 part; confirm against Apple's G16 output (`metal-nt`) | 1–2 weeks |
| U3 | GL desktop (Gallium asahi on AGX3b) on a compositor | follows K and U1/U2; days if aurora's state holds |
| U4 | Our own G16 backend without aurora (applegpu-style RE from G13) | 6–12+ months; not recommended |

---

## C. Display path without DCP

The project shows the screen through **simpledrm** on iBoot's boot
framebuffer. That is a KMS device with one fixed mode, one primary plane,
no hardware vblank, and system-memory (shmem) buffers whose damage is
copied by the CPU into the framebuffer. DCP for T604x is "TBA" upstream.
aurora has DCP branches (`apif-dcp-afk`, `drm/dcp-audio-26-abi`), also
tied to 26.x firmware ABIs.

How a GPU-rendered desktop gets onto it:

1. **drm/asahi is render-only** (no KMS); it exposes `/dev/dri/renderD*`.
   The compositor needs a separate KMS device, which here is simpledrm on
   `card0`.
2. **Multi-GPU compositor path** (wlroots, KWin and mutter all support it).
   The compositor renders with EGL/Vulkan on the asahi render node. Each
   frame then goes to simpledrm in one of two ways:
   - **PRIME import:** export a linear dma-buf from asahi and add it as a
     framebuffer on simpledrm. simpledrm uses the GEM shmem helpers, so
     the import needs a `vmap`-able dma-buf. Its damage handler still
     memcpys into the framebuffer, so this is a single copy on the CPU.
   - **Fallback:** the compositor copies from a GPU buffer into a
     simpledrm dumb buffer with the CPU (wlroots and KWin do this when
     import fails).
3. **Mesa kmsro:** Gallium's render-only glue lists specific KMS drivers.
   simpledrm is not one of them, so a client opening `card0` directly gets
   llvmpipe. Compositors that open the render node themselves are fine.
   Clients render on the render node anyway.

Costs and limits:

- Full-screen damage at 3456×2234×4 B is about 31 MB per frame, or about
  1.8 GB/s at 60 Hz of CPU memcpy. The M4 Pro can sustain that, but it
  costs CPU time and power. Damage tracking makes the common case small.
- No real vblank or page flip, so expect tearing. Pacing comes from a
  timer, not the display. There is no 120 Hz (ProMotion), no VRR, no
  HDR, and only the mode iBoot set.
- No backlight or panel power control through DCP. External displays do
  not work.
- Rendering still moves fully to the GPU (clients and composition), so
  this is a large improvement over llvmpipe even with the copy.
- Long-term fix: DCP on 27.2 (a separate RE project, also firmware-version
  specific), or scanning out of a GPU-written buffer if the DCP can be
  told to show a buffer at a fixed address. Neither is needed for a first
  GPU desktop.

---

## Effort summary

| Path | To first triangle in Linux | To GPU-composited desktop (simpledrm) |
|---|---|---|
| aurora kernel + Mesa, **26.6.2** firmware | ~2–3 weeks (K1, K8, K9, U1) | +1–2 weeks |
| aurora kernel + Mesa, **27.2** variant (our goal) | ~6–10 weeks (K1–K9, U1–U2) | +1–2 weeks |
| Upstream Asahi only, our own G16 Mesa | 4–6 months kernel + 6–12 months Mesa | — |

## Recommended order of work

1. **Pin aurora as reference.** Record commit ids, read `hw/t6040.rs`,
   `g17/fw/initdata/v25g83.rs` and `g17/fw/variant.rs`, and convert their
   25G83 layouts into our `.sexp` schemas as the "closest known" input to
   `agx fit` (plan step 4). This is a far better starting point than 13.5.
2. **Close the A.3 table with traces we already have.** Fit 25G83 → 27.2
   for Root (0xc8), HwData (60 slots), WorkSlot, PointerBlock,
   QueueConfig and KickPredecessor. Use aurora's entropy-record rule for
   our firmware id.
3. **Phase 3 (host bring-up) on aurora's structures:** boot the 27.2
   firmware from the m1n1 proxy with generated defs, as the plan says,
   but using aurora's init graph (status-word init ack, `qid_floor`).
4. **Calibration and DT (K9)** in parallel; the 16-core masks (K8) are the
   main hardware risk.
5. **Kernel (K1–K7):** add the `V27_2` variant and the 27.2 T6040 `Build` to
   aurora's driver, generated from our schemas. Keep it a non-autoloaded
   module in its own boot generation. Optionally first validate the
   machine on 26.6.2 firmware with unmodified aurora, to separate
   "16-core/DT bugs" from "27.2 layout bugs".
6. **Mesa (U1–U2):** aurora `aurora-wip` packaged in Nix, matched to the
   kernel commit; kmscube/glmark2 on the render node, then a wlroots or
   KWin session composited onto simpledrm (C.2).
7. **Later:** offer the 27.2 variant upstream to aurora (it is the same
   interface family), then DCP as its own project.
