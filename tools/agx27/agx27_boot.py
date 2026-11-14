#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""DRAFT, NEVER RUN: boot the AGX 27.2 firmware on the M4 Pro from the host.

Phase 3 of docs/gpu/plan.md. The 27.2 counterpart of
upstream/m1n1/proxyclient/experiments/agx_boot.py + m1n1/agx/__init__.py
(AGX.start). Steps and open problems: tools/agx27/README.md. This will NOT
boot the firmware as is: RegionA/RegionC, the four InitData pointers and the
RegionB auxiliary channels are not decoded (see README "Gaps"); with
--clone-undecoded they are copied from a macOS snapshot, which embeds macOS
VAs and is only a probe.

Refuses to do anything without --i-know-this-writes-to-the-gpu.
"""

import argparse, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import layouts as L
import build_initdata as B

# Our kernel-half VA plan (any free range in the 0xfffffc.. half the firmware
# can see; macOS used 0xfffffc20_00000000.. for objects and
# 0xfffffc21_80000000.. for io). Kept disjoint from macOS's so a confused
# firmware access shows up as a fault rather than a silent hit.
KVA_OBJ = 0xFFFFFC2400000000      # InitData, regions, HwDataB, channels
KVA_IO = 0xFFFFFC2580000000       # io_mappings
KVA_SRAM = 0xFFFFFC2500108000     # sgx_sram_ptr


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--i-know-this-writes-to-the-gpu", dest="armed", action="store_true")
    ap.add_argument("--clone-undecoded", metavar="SNAPSHOT_DIR",
                    help="fill RegionA/C and the +0xa8..+0xc0 targets from a macOS snapshot (probe only)")
    a = ap.parse_args()
    if not a.armed:
        sys.exit("draft: not armed (see README.md before running anything)")

    sys.path.insert(0, os.path.join(REPO, "upstream", "m1n1", "proxyclient"))
    from m1n1.setup import p, u            # connects to m1n1 (M1N1DEVICE)
    from m1n1.hw.uat import UAT, MemoryAttr
    from m1n1.fw.agx import AGXASC

    adt = u.adt
    g = B.GpuAdt.from_adt(adt)
    assert g.chip_id == 0x6040, f"chip {g.chip_id:#x}: T6040 only"
    sgx = adt["/arm-io/sgx"]

    # 1. Power: afr before gfx (lib/boot/gpu_probe.ml with_chain_active; gfx
    #    alone hangs the bus on the first SGX read). m1n1 resolves the chain
    #    from the ADT clock-gates/power-gates (0x190 afr, 0x192 gfx).
    p.pmgr_adt_power_enable("/arm-io/sgx")
    p.pmgr_adt_power_enable("/arm-io/gfx-asc")

    # 2. Firmware identity: perf maps live (must match the table we built for).
    maps = B.read_pstate_maps(p, g.sgx_base)
    assert [m[:11] for m in maps] == B.PSTATE_MAP_T6040, maps

    # 3. UAT: reuse the kernel-half TTBR1 that iBoot built in gfx-shared-region
    #    (root 0x105fff78000; L1 slot 0 = firmware, 1 = device regs, 2 = macOS
    #    objects), as m1n1 does. G15+ layout: L0_OFF 42 (m1n1 hw/uat.py), which
    #    matches 27.2's 36/25/14 + 42-bit halves. Context 0 TTBR0 for user maps.
    uat = UAT(u.iface, u)
    # m1n1 UAT.init: zeroes TTBR1 L1 entries 2.. (slot 2 = macOS's 0xfffffc20.. table
    # in gfx-shared-l2-region; we rebuild it), keeps 0 (firmware) and 1 (device
    # regs), takes the handoff lock and writes ctx 0's TTBR0/TTBR1 at gpu-region-base.
    # TODO: confirm the handoff struct (gfx-handoff-base) still has 13.x's layout.
    uat.init()

    heap_va = [KVA_OBJ]

    def alloc(size, attr=MemoryAttr.Shared):
        size = (size + 0x3FFF) & ~0x3FFF
        phys = u.memalign(0x4000, size)
        p.memset8(phys, 0, size)
        va = heap_va[0]; heap_va[0] += size + 0x4000
        uat.iomap_at(0, va, phys, size, AttrIndex=attr, AP=1, UXN=1)  # macOS PTE ..44b: Shared, AP=1, UXN, OS
        return va, phys

    def put(va_phys, data):
        p.iface.writemem(va_phys[1], data)

    # 4. Objects. Sizes beyond the decoded heads are guesses (README).
    hwdb = alloc(0x20000)                  # HwDataB (0x2850) + RegionB in one block, like macOS
    regb = (hwdb[0] + 0x1E940, hwdb[1] + 0x1E940)
    states = alloc(0x4000)                 # 13 x 0x40 channel counters (TA/3D/CL arrays) + devctrl
    rings = alloc(13 * 0x1800)
    region_a = alloc(L.REGION_A_SIZE)
    region_c = alloc(max(L.REGION_C_MIN_SIZE, 0x4000))
    p_a8 = alloc(0x4000); p_b0 = alloc(0x8000); p_b8 = alloc(0x4000); p_c0 = alloc(0x4000)
    counters = alloc(0x4000); unk_27e0 = alloc(0x4000); ts = alloc(0x4000)
    initdata = alloc(0x4000)

    if a.clone_undecoded:
        import snapshot as S
        snap = S.Snapshot(a.clone_undecoded)
        ir = L.InitData27.parse(snap.read(snap.init_va(), L.InitData27.size))
        for dst, src, n in ((region_a, ir["region_a"], L.REGION_A_SIZE), (region_c, ir["region_c"], L.REGION_C_MIN_SIZE),
                            (p_a8, ir["ptr_a8"], 0x4000 - (ir["ptr_a8"] & 0x3FFF)),
                            (p_b0, ir["ptr_b0"], L.PTR_B0_MIN_SIZE), (p_b8, ir["ptr_b8"], L.PTR_B8_MIN_SIZE)):
            data = snap.read(src, n)
            if data:
                put(dst, data)   # TODO: contains macOS VAs; relocate once the layouts are known

    # 5. io_mappings + SGX SRAM into the GPU kernel half (Device / Shared).
    ptrs = B.HwDataBPointers(timestamp_region_base=ts[0], sgx_sram_ptr=KVA_SRAM,
                             counter_ctl=counters[0], unk_27e0=unk_27e0[0],
                             hw_rings=[None] * 4,   # TODO: macOS sets slots 0 and 2; firmware may need them
                             io_va_base=KVA_IO)
    hwdb_bytes, maps_needed = B.build_hwdata_b(g, ptrs)
    for m in maps_needed:
        attr = MemoryAttr.Device if m.kind == "device" else MemoryAttr.Shared
        uat.iomap_at(0, m.va, m.phys, m.size, AttrIndex=attr, AP=1, UXN=1)
    put(hwdb, hwdb_bytes)

    regb_bytes = B.build_regionb(hwdb[0], hwdb[0] + 0xC880, states[0], rings[0],
                                 devctrl_state=states[0] + 0x300, devctrl_ring=rings[0] + 12 * 0x1800)
    put(regb, regb_bytes)

    init_bytes = B.build_initdata(region_a[0], regb[0], region_c[0], p_a8[0], p_b0[0], p_b8[0], p_c0[0])
    put(initdata, init_bytes)
    uat.flush_dirty()

    # 6. RTKit: start gfx-asc, HELLO (version 12 seen), start EP 0x20/0x21.
    # agx=None: FirmwareEP's 0x42 handler calls agx.poll_channels(); a real run
    # needs a small object with poll_channels() (read the event/log rings).
    asc = AGXASC(u, adt["/arm-io/gfx-asc"].get_reg(0)[0], None, uat)
    asc.start()
    asc.start_ep(0x20)
    asc.start_ep(0x21)

    # 7. InitData: type 0x81 on EP 0x20, VA in bits 47:0 (firmware ORs 0xfffff00000000000).
    msg = B.msg_initdata(initdata[0])
    print(f"sending InitData {initdata[0]:#x}: {msg:#018x}")
    from m1n1.fw.agx import GpuMsg
    asc.fw.send(GpuMsg(msg))   # FirmwareEP.send_initdata/InitMsg use 44 bits; send all 48

    # 8. Expect: no "Host and FW Interface is mismatched" (ver_info), no
    #    "Host-mapped FW allocations are disabled" (+0x2c); then the firmware
    #    pings EP 0x20 (type 0x42) and starts polling channels. Watch the
    #    syslog/crashlog endpoints and the fault registers.
    t0 = time.time()
    while time.time() - t0 < 5:
        asc.work()


if __name__ == "__main__":
    main()
