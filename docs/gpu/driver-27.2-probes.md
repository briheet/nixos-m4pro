# Aurora's GPU driver on the 27.2 firmware: probe log

The J614s runs nixos-aurora with our GPU driver patches
(`~/nix-config/modules/j614s/gpu-patches/`, built out of tree as
`aurora.ko`; blacklisted at boot while this is brought up, loaded by hand
with `modprobe -d /run/current-system/kernel-modules aurora` after a
fresh boot). Each probe is one reboot plus a load. The structure map is
[driver-27.2-diff.md](driver-27.2-diff.md).

## 2026-11-15

| Patches | What happened | Next |
|---|---|---|
| none (aura 0001 only) | GPU node okay; driver refuses: `unsupported GPU firmware build: TEXT 0x64000 DATA 0xc4000 entropy 0x5d88c/0x5d96f sha256 eda53a91…` | admit it |
| 0001 admit (V27_2 = 25G83 rules) | MMU and RTKit start. The firmware asks for its RTKit buffers on ep 0x1 (0x8000, then 0x1000) at 0x10001d90000, the `__DATA_SHARED_RO` segment; the driver refuses (-22). No InitData ack, probe times out (-110) | accept that segment |
| 0002 buffers in shared-ro | Buffers accepted. Host sends InitData (ep 0x20, `0x0081…`); firmware crashes: *"Host and FW Interface is mismatched, please ensure the versions are aligned."*, as firmware-decode.md predicted | write 27.2's version |
| 0003 interface version 0x0c8b6339839804c0 | Version accepted. Firmware data-aborts: EL1 write, FAR 0x930, PC TEXT+0x3808 in fn_3420: `x8 = *(u64 *)(ctx + 0x481); *(u32 *)(x8 + 0x930) = 0x3dd00000`, where ctx = the global 0x11e9e8 = InitData+0x18 (fn at 0x32318). The driver's 25G83 root puts its MainConfig there, which has no pointer at +0x481 | lay InitData+0x18's block out the 27.2 way (diff doc) |
| 0004 pointers 0x40/0x50, opening opcode 0x15, MainConfig +0x481 and macOS's words (diff items 2, 3, 5) | +0x481 crash gone; firmware runs ~2 ms further. Data abort: EL1 read, FAR 0xa0, PC TEXT+0x2d584 (fn_2d57c, called at 0x3de8c in `agfReadPmpAFRPerfStateRequest` beside "AGFAfrPerfStateInit"): `*(u32 *)(*(u64 *)0x11ff40 + 0xa0)`, global 0x11ff40 still null. No direct store to it in the disassembly (set through a register base or a copy) | power state, HwData, PowerConfig the 27.2 way (diff items 10, 13, 14); find what fills 0x11ff40 |
| 0005 dump (bring-up), 0006 27.2 HwData, PowerConfig, power state (diff items 10, 13, 14) | **Probe succeeds**: no firmware crash, `[drm] Initialized aurora 1.0.0 for 28a600000.gpu on minor 1`, /dev/dri/renderD128. The translated blocks equal macOS 27.2's at its InitData message except our own VAs (register windows, rings, QoS, SRAM, +0x27e0 page, config and AON pointers), HwData +0xe0..+0x5ec (left zero) and table A's relative-performance fractions | idle stability; then submission: queue record, device-control opcodes, kick path (diff items 11, 15, 16) and Aurora Mesa |
| 0006 + `tools/gpu-smoke` (Aurora Mesa, EGL surfaceless GLES2: clear + triangle + readback) | Mesa: `GL_RENDERER: Apple M4 Pro (G16S B1)`, ES 3.2. Render on QIDs 34/35 times out after the firmware consumed every command (tiler cursors done = read = write = 4, fragment 3/3) without writing completion stamps (stamps 0, recovery state 0); no firmware crash, firmware still up; the client's VM is then poisoned (-110). Mesa also dropped one draw ("no G17P fragment program could be built") | submission path for 27.2: queue record, device control, kick (diff items 11, 15, 16) |
| 0007 27.2 device control, Region C, render submission (M5 record and item forms, event 254) | Firmware consumes the new rings (TA: lead, 0xf, 0x10; 3D: 0xf, 0x10); job list now empties; still no stamps, render times out | firmware's own view |
| 0008 firmware log (MainConfig +0x250) | Log works: "G16 Firmware initializing", "FW Build variant: g16s", "running in SKSM Enabled mode", GIN-1114 init, CRE save, "AON PTD Enable mask is 0 for Fabric". Nothing about our kick. Region C now equals macOS's but for unk_78 (fixed in 0008) | compare our records with macOS byte for byte |
| 0009 dependency control 0x0fa0, record dump | Our kick entries, dependencies, event mask, 0xf and 0x10 records match macOS's layout (header differs only by QID, which sits at bit 42). Firmware decode (§18.1): QIDs < 128, free-list slots < 256, first-config flags all accepted | read back the live state |
| 0010 live read-back on timeout | Hold bit 254 is cleared on both entries (the 0x10 found them), but nothing ran: pass records 0, queue record +0x1c/+0x54/+0x68 still 0 (macOS: +0x1c == done). The kick is released and never dispatched | trace SKSM dispatch after release (§18.2) |
| 0011 status B 27.2 layout (firmware-control pointers +0x4ac0/+0x4ac8 as macOS has them at InitData; recovery words +0x1e0; +0xe714 = 1) | Same timeout. KSM queue-valid/invalid registers (sgx +0x21068..+0x21080, read through /dev/mem after the timeout) all read 0; inconclusive (write-to-set registers, or the block reads 0 powered down) | GPU power |
| 0012 host idle timestamp: Region C +0x98c = counter, 200000, then device control 0x22 before keep-powered 0x0a (macOS sends six 0x22 before its first kick) | 0x22 and 0x0a published; same timeout. The firmware sent no event at all (macOS's firmware sends thousands of 0x42 notices) | whether the GPU powers up at all; the TA register program |
| 0013 descriptor dump + power domains while pending | GPU power domains `gfx`, `afr`, `pmp-gfx` on (idle and pending). Our TA descriptor (0x9c0) equals macOS 27.2's triangle TA descriptor (27.2-triangle2/08, QID 26) in 540 of 624 words; the rest are allocation addresses, target size (64×64), timestamps and object IDs (ours 2/4, macOS 0x0a00d1e8/0x0b00ddcf), free-list slot (0x81 vs 2), and the tiler status word: ours a kernel-lower alias 0x70_8000_8000 (register +0x424 0x70_8000_8001), macOS K+0x1839ac0 (register 0x10_0007_9ac1). No structural difference | KSM programming on install (SKSM), object IDs |
| 0014 HwData +0x2730 = 0 (firmware installs the queues; §18.3), items [lead], 0xf, 0xe announcement, no hold bit | **The work runs**: pass records hold start timestamps (TA 0x35e37489, 3D 0x35e375b7 12 us later, so the KSM saw the TA kick complete); queue record +0x1c = 3 / 2 (firmware dispatch write). Still no stamps, no events, record +0x54/+0x68 = 0: completion never reaches the firmware or the host. KSM valid registers read 0 afterwards | completion path vs +0x2730; or the macOS mode (+0x2730 = 1, host-port install) (§18.4) |
| 0015 descriptor item back in the rings ([lead], descriptor, 0xf, 0xe) with +0x2730 = 0 (§18.4) | **First render on 27.2 passes**: `tools/gpu-smoke` reads back the red clear and the green triangle (`PASS`). The firmware posts completion events (type 1, stamp masks bit 34 and bit 35) and the render completes | compute queues (0x80 record), drop the bring-up logging, stress, then Aurora Mesa as the system GL |
| clean: nix-config `gpu-patches/0001-t6040-macos-27.2-gpu-firmware.patch` (0001-0015 condensed, bring-up logging dropped; compute queues use the 0x80 record) | `tools/gpu-smoke` with a compute case: render PASS (red clear, green triangle) and compute PASS (64 invocations write i * 3 + 7 to a storage buffer, read back). Kernel log clean | stress: many frames, several clients, idle power-off and wake-up; then load at boot and Aurora Mesa as the system GL |
| stress (`tools/gpu-smoke/stress.sh`, clean patch) | One client 2000 iterations of render + compute (values change each iteration, every result checked): 0 failures, 680 ms. Four clients × 500 in parallel: all pass, 250 ms. 50 iterations 200 ms apart (idle power-off and wake): 0 failures. vkmark 2025.01 headless on Aurora's Vulkan (`Apple M4 Pro (G16S B1)`, device 0x6040): all 13 scenes, score 11321. Kernel log: no timeout, fault, recovery or crash | load at boot; Aurora Mesa as the system GL for Hyprland |

Notes:

- The firmware runs to the InitData message the same way under 27.2 as
  under 25G83 (mailbox history identical up to #014): RTKit, the buffer
  requests, ep 0x20/0x21 start. The differences begin inside InitData.
- After a crash the coprocessor stays dead until reboot; a reload of
  aurora.ko on a crashed firmware is not a valid test.

## How the 0006 blocks were made

The 25G83 blocks the driver builds were logged (patch 0005) and compared
with macOS 27.2's (`build/agx/traces/27.2-boot5/01-first-app-tx-ep0x20`:
HwData at bundle `K+0xc07a0000`, PowerConfig at bundle+0x5380, power state
at `K+0x2ea80`). Scratch scripts modelled the run moves of
driver-27.2-diff.md §9/§10 and were refined at the run boundaries until
only expected differences were left; the driver code
(`g17/fw/initdata/v27_2.rs`) is that model. Findings beyond the diff doc:

- HwData relative performance: table B is exactly 100·(f − f₁)/(f_top − f₁)
  over table A's frequencies; table A's f32 values are the device tree's
  whole percents plus a fraction (9 → 9.689) whose formula is unknown.
- HwData table A replicates lane 0 into lanes 2–15; +0x26b0 = 0x1e0000.
- HwData +0xe0..+0x10c, +0x2d8..+0x2ec, +0x3e0..+0x40c, +0x5d8..+0x5ec:
  host-written (present at the InitData message, unchanged later), look
  like packed calibration curves, possibly per unit. Left zero; the
  firmware boots without them.
- `sgx_sram_ptr` (+0xfa0) names the GPU SRAM (phys 0x2_88d6_0000), which
  register window slot 37 already maps; the driver points it there.
- PowerConfig run boundaries: 0x2870 stays +0x10; +0x28 runs to 0x2c48;
  8 bytes go between 0x2c48 and 0x2c50; the AON block (0x6318..0x6378)
  moves +0x28; entropy and leakage words have no 27.2 place.
