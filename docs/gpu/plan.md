# GPU (AGX) on the J614s: plan

Goal: GPU acceleration on this Mac (M4 Pro, `gpu,t6040`, 16 GPU cores with
12 CPU cores) with the GPU firmware it actually runs, the one iBoot loads
from the macOS 27.2 stub volume (`macostest`). No driver anywhere speaks
that firmware: Asahi stops at M2, aurora-silicon accepts only macOS 26.6.2
(its driver refuses anything else by hash). We write our own support, and
we write it so that the next macOS firmware is a data change, not a port.

Status: planning (2026-11-14). `nixos-m4pro gpu ADT` already decodes the
GPU's ADT nodes (perf tables, regions, firmware segments).

## How the GPU is driven

What a driver has to get right, layer by layer:

| Layer | What it is | Changes with the firmware? |
|---|---|---|
| Firmware image | `gfx-asc` coprocessor; iBoot loads `__TEXT`, `__DATA`, `__DATA_SHARED_RO` (ADT `segment-ranges`) | It *is* the version |
| RTKit | mailbox protocol to `gfx-asc` (boot, power, system endpoints); we already run RTKit for ANS, PMP, MTP | Rarely |
| Init data | a large tree of structures the host builds before boot (regions A/B/C, HwDataA/B: power, calibration, clocks) | **Yes, every release** |
| Channels | ring buffers in shared memory: device control, events, firmware log, statistics, ktrace | Some |
| Command queues | render/compute/blit queues, work commands, microsequences, event stamps | **Yes** |
| UAT | the GPU's MMU: page tables in the handoff/shared regions iBoot reserved | Rarely |
| Calibration | per-unit values in the device tree (core mask, perf maps, leakage from fuses) | No (per chip) |
| Shaders / Mesa | G16 instruction set, command-buffer encoding in userspace | Per GPU generation |

The firmware-specific part is the structure layouts: the same fields, with
some inserted, removed or resized in each release. Asahi encodes this as
per-version conditions on struct fields (Rust `#[versions]`, Python
`construct` with `Ver(...)` checks). We make that a first-class, checked
data format with tools around it.

## The tools we build (OCaml, `lib/agx/`, `nixos-m4pro agx ...`)

1. **Firmware identity** (`agx fw-id`). Read the loaded `__TEXT` over the
   m1n1 proxy (or from a dump), hash each segment, extract its version and
   build strings. Every later artefact is keyed by this id; the kernel
   driver refuses an unknown id instead of hanging the GPU.

2. **Layout schemas** (`firmware/agx/*.sexp`). Each firmware structure once,
   as data: fields with types (u8..u64, f32, pointers, arrays, nested
   structs, padding) and version gates (`(since 27.2)`, `(until 26.6)`,
   `(size 27.2 0x40)`). OCaml loads and checks them (sizes add up,
   alignment, known totals) and computes the layout for one firmware id.
   One file per family (initdata, channels, queues, work commands), so a
   new release shows up as a small git diff.

3. **Trace ingest and decode** (`agx decode`). The m1n1 hypervisor tracer
   (Python, `proxyclient/hv/trace_agx.py`, adapted to T6040 addresses)
   writes a structured log: mailbox messages, MMIO, and snapshots of shared
   memory (address, bytes) at events. OCaml reads it and decodes any
   region with a schema: init data at boot, channel entries, queued work.
   Output is a typed tree we can read, diff and test against.

4. **Layout fitting** (`agx fit --from 26.6.2 dump`). For a new firmware,
   start from the closest known schema and let anchors place the fields:
   values we know independently (region bases and sizes, perf states and
   voltages from the ADT, calibration we computed, pointers into known
   regions, counts) are searched for in the dump, and the tool proposes the
   inserted/removed/resized fields that make them line up. A human reviews
   and commits the schema diff. This is the step that makes future
   versions cheap.

5. **Round trip** (`agx check`). Decode a traced structure and re-encode it
   from the typed tree; the bytes must match. Every schema change runs
   against every trace we keep (`test/agx/`, traces stored compressed, keyed
   by firmware id; Apple's firmware itself is never committed).

6. **Code generation** (`agx gen rust|python|c`). From the schemas, per
   firmware id: Rust structs for the kernel driver (`drm/asahi` style),
   Python `construct` definitions for m1n1 proxyclient experiments, C for
   m1n1 if needed. Adding a firmware = schema diff + regenerate.

7. **Calibration** (`agx calib`). From the ADT plus a few reads of our own
   unit (core mask at SGX `+0xe01500`, perf maps at `+0xe01400`, leakage
   fuses at `0x508374c10..`), compute the device-tree values m1n1 fills for
   older chips (`apple,core-mask`, perf maps, leak coefficients, max power,
   operating points) and emit the GPU node. Reference arithmetic: m1n1
   `src/kboot_gpu.c` (M1/M2) and aurora's `dt_set_gpu_t6040` (M4).

## Phases

| # | Phase | Output | Rough size |
|---|---|---|---|
| 0 | Ground truth | `docs/gpu/facts.md`: macOS `ioreg -l -r -c AGXAccelerator`, `powermetrics --samplers gpu_power`, firmware id, core mask and fuses read over the proxy | 1 day |
| 1 | Tracing | `trace_agx` running on T6040 under our hypervisor; logs of GPU firmware boot, idle, and a minimal Metal triangle app we write; OCaml ingest | ~1 week |
| 2 | Schemas | Schemas for 27.2 init data and channels, fitted from Asahi's last layouts (and aurora's 26.6.2 as a second reference); round trip passing on our traces | 1–2 weeks |
| 3 | Host bring-up | m1n1 proxyclient driver (`agx_boot`, `agx_1tri` on generated defs) boots the GPU firmware from the host, then draws one triangle with a shader binary captured from macOS | 1–2 weeks |
| 4 | Calibration and DT | `agx calib` output in our m1n1 (patch) or the kernel DT; GPU node, mailbox, power domains, six reserved regions | days, in parallel |
| 5 | Kernel driver | Asahi's `drm/asahi` structure with a T6040 hardware file and generated 27.2 structs; a module, never auto-loaded, in its own boot-menu generation | several weeks |
| 6 | Userspace | Mesa for G16 (Asahi's M3 instruction-set work plus M4 deltas); and how frames reach the screen without DCP (open question) | long; separate plan |

Milestones: firmware id recorded (0); GPU firmware boot traced and decoded
(1–2); GPU firmware booted by us from the host (3); a triangle from the
host (3); the kernel driver booting the firmware (5); a triangle in Linux (5–6).

## Safety

- Read-only first: phases 0–2 only observe (macOS under the hypervisor,
  proxy reads). Nothing is written to the GPU until phase 3.
- The driver checks the firmware id and refuses unknown ones.
- Calibration is computed from this unit and checked; on any inconsistency
  the GPU node stays disabled.
- Phases 3–5 run tethered or as a separate generation; the daily system
  keeps simpledrm and llvmpipe. Hangs reset through U-Boot's watchdog or
  `tools/m4reboot`; Linux clears iBoot's failed-boot count on every boot.
- The 12-CPU/16-GPU configuration has not been run by anyone; expect the
  core mask and per-cluster tables to need care.

## References

- Asahi: [Tales of the M1 GPU](https://asahilinux.org/2022/11/tales-of-the-m1-gpu/),
  m1n1 `proxyclient/hv/trace_agx*.py`, `proxyclient/m1n1/agx/`,
  `proxyclient/m1n1/fw/agx/`, `experiments/agx_*.py`, `src/kboot_gpu.c`;
  the `drm/asahi` Rust driver in AsahiLinux/linux.
- Alyssa Rosenzweig, [Dissecting the Apple M1 GPU](https://rosenzweig.io/blog/asahi-gpu-part-1.html)
  (wrap.dylib, agxdecode; now in Mesa).
- Dougall Johnson, [applegpu](https://dougallj.github.io/applegpu/docs.html) (G13 instruction set).
- aurora-silicon: `drivers/gpu/drm/asahi/hw/t6040.rs`, aura `src/kboot_gpu.c`
  (`dt_set_gpu_t6040`), linux discussion #129 (M4 status).
