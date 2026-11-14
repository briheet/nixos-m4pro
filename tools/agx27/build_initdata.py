#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the AGX 27.2 boot structures for the M4 Pro (T6040, J614s) from the ADT.

Pure functions: ADT in, bytes out (plus the list of UAT mappings the bytes
assume). No device access; agx27_boot.py is what would put them in memory.

Replaces m1n1 proxyclient/m1n1/agx/initdata.py (build_initdata,
build_iomappings, CHIP_INFO) for firmware 27.2. Rules for every derived
field are in lib/agx/hwdata.ml and docs/gpu/firmware-decode.md; values
without a rule are the macOS 27.2 snapshot's (boot5, 03-after-5000-msgs)
and are marked SNAPSHOT.

Self-test (offline):
    .venv-m1n1/bin/python tools/agx27/build_initdata.py [--adt build/adt.bin] [--snap DIR]
builds HwDataB from the ADT and diffs it against macOS's HwDataB in the
snapshot, field by field.
"""

import argparse, os, struct, sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)

import layouts as L

PAGE = 0x4000
SGX_REG_BASE = 0x288000000          # ADT /arm-io/sgx reg 0
IO_VA_BASE_MACOS = 0xFFFFFC2180000000  # where macOS put the io_mappings

# --------------------------------------------------------------------------
# ADT

def load_adt(path):
    """m1n1's ADT parser on a raw ADT blob (build/adt.bin)."""
    sys.path.insert(0, os.path.join(REPO, "upstream", "m1n1", "proxyclient"))
    from m1n1 import adt
    with open(path, "rb") as f:
        return adt.load_adt(f.read())


@dataclass
class GpuAdt:
    """What the builder needs from /arm-io/sgx, in MHz / mV."""
    chip_id: int
    num_perf_states: int            # gpu-num-perf-states (15; state 0 = off not counted)
    perf: list                      # [table][state] -> (MHz, mV), 2 x 16
    perf_sram: list                 # same, SRAM rail
    afr: list                       # [(MHz, mV)] (afr-perf-states die 0)
    afr_min_sram_mv: int
    power_sample_period: int
    sgx_base: int

    @classmethod
    def from_adt(cls, adt):
        sgx = adt["/arm-io/sgx"]
        n = sgx.perf_state_count               # 16 entries per table
        tables = sgx.perf_state_table_count    # 2
        ps = sgx.getprop("perf-states")
        sr = sgx.getprop("perf-states-sram")
        # m1n1 parses perf-states as all tables concatenated (table j at j*n), as in 13.x.
        perf = [[(ps[j * n + i].freq // 1000000, ps[j * n + i].volt) for i in range(n)] for j in range(tables)]
        sram = [[(sr[j * n + i].freq // 1000000, sr[j * n + i].volt) for i in range(n)] for j in range(tables)]
        # perf-states1 / -sram1 duplicate table 1; check rather than trust.
        p1 = sgx.getprop("perf-states1", None)
        if p1 is not None and tables > 1:
            assert [(p.freq // 1000000, p.volt) for p in p1] == perf[1], "perf-states1 != perf-states table 1"
        afr = sgx.getprop("afr-perf-states")
        return cls(
            chip_id=adt["/chosen"].chip_id,
            num_perf_states=sgx.gpu_num_perf_states,
            perf=perf, perf_sram=sram,
            afr=[(p.freq // 1000000, p.volt // 1000) for p in afr.states[0][:afr.count]],
            afr_min_sram_mv=afr.min_sram_volt[0] // 1000,
            power_sample_period=sgx.gpu_power_sample_period,
            sgx_base=sgx.get_reg(0)[0],
        )

# --------------------------------------------------------------------------
# Per-chip data that is not in the ADT

# Perf maps: SGX +0xe01400 (main) and +0xe01480 (alt), read live by
# `nixos-m4pro gpu-probe` (docs/gpu/facts.md); needs afr+gfx powered.
# They equal HwDataB.pstate_map[0] / [1] in the macOS snapshot.
PSTATE_MAP_T6040 = [
    [0, 1, 2, 3, 4, 6, 8, 10, 12, 14, 15],
    [0, 1, 2, 3, 4, 6, 7, 9, 11, 13, 15],
]

def read_pstate_maps(p, sgx_base):
    """Live read (for agx27_boot.py; gfx domain must be up). Two 4-bit indices per u32, 8 words."""
    maps = []
    for off in (0xe01400, 0xe01480):
        idx = []
        for k in range(8):
            w = p.read32(sgx_base + off + 4 * k)
            idx += [w & 0xf, (w >> 16) & 0xf]
        maps.append(idx)
    return maps

# SNAPSHOT: rel_max_powers has no formula yet (13.x used a per-chip table too).
REL_MAX_POWERS_T6040 = [0.0, 9.688556671142578, 17.169883728027344, 23.879650115966797,
                        30.335752487182617, 39.24570083618164, 50.038753509521484,
                        61.12070083618164, 70.3812026977539, 79.7896728515625, 100.0]

# io_mappings, indexed by kAGFIPIORegionType id. (slot, phys, size, range_size, rw, flags)
# rw: write sgx_offset = phys - 0x288000000 (13.x "readwrite"); PMPDoorbell and
# GFXCLKGENMGPU are inside the GPU window but macOS gives them 0, so it is per slot.
# SNAPSHOT values (boot5); docs/gpu/firmware-decode.md "HwDataB".
IO_MAPPINGS_T6040 = [
    (0x00, 0x502414000, 0x4000,   0x4000,   0, 2),  # MCacheRegisters
    (0x03, 0x2201c4000, 0x60000,  0x18000,  0, 2),  # MTRPMSRegisters
    (0x04, 0x50244c000, 0x4000,   0x4000,   0, 0),  # GPCAICSWInt
    (0x09, 0x5003d0000, 0x4000,   0x4000,   0, 2),  # SpecialAgentIdleDie1
    (0x0a, 0x5003c0000, 0x4000,   0x4000,   0, 0),  # PushTelemetryDashboardConfigSpace
    (0x0b, 0x5003d8000, 0x4000,   0x4000,   0, 2),  # PushTelemetryDashboard
    (0x0c, 0x48565c000, 0x4000,   0x4000,   0, 2),  # GFXCAXI2AFRegisters
    (0x0e, 0x500400000, 0x10000,  0x10000,  0, 0),  # MTRRegisters
    (0x0f, 0x50cdc0000, 0x4000,   0x4000,   0, 0),  # ANE1Registers
    (0x11, 0x288000000, 0x21400,  0x21400,  1, 2),  # GPU registers (sgx reg 0); firmware's main base
    (0x14, 0x28b000000, 0x100000, 0x40000,  0, 2),  # (unnamed; AFRClkGen?)
    (0x16, 0x289000000, 0x8000,   0x8000,   0, 2),  # AFRD2DNIRegisters
    (0x1f, 0x288d04000, 0x8000,   0x8000,   1, 2),  # (runtime-named)
    (0x21, 0x288d58000, 0x8000,   0x8000,   1, 2),  # GMGIFAFRegisters
    (0x22, 0x288d10000, 0x4000,   0x4000,   1, 2),  # CRERegisters
    (0x24, 0x288d40000, 0x4000,   0x4000,   1, 2),  # FenderRegsKSMFE
    (0x25, 0x288d60000, 0x20000,  0x20000,  1, 2),  # FenderRegsMCW
    (0x26, 0x288d44000, 0x4000,   0x4000,   1, 2),  # FenderRegsScratchRam
    (0x27, 0x288d4c000, 0x200,    0x200,    1, 2),  # FenderRegsBumper
    (0x28, 0x288e00000, 0x4000,   0x4000,   1, 2),  # FenderRegsPRC
    (0x2a, 0x288e40000, 0x4000,   0x4000,   1, 2),  # FenderRegsDFenderPowerTransG16G
    (0x2c, 0x288e08000, 0x8000,   0x8000,   0, 2),  # PMPDoorbell
    (0x2d, 0x288e1c000, 0x4000,   0x4000,   1, 2),  # FenderRegsIVDM
    (0x2e, 0x288e1f800, 0x4000,   0x4000,   0, 2),  # GFXCLKGENMGPU (not page aligned)
    (0x30, 0x288e60000, 0x58,     0x58,     1, 2),  # AVMRControllerFastRegisters
]
# Empty slots that still carry flags = 2 under macOS (meaning of the flag: open).
IO_EMPTY_FLAG2_T6040 = [0x02, 0x05, 0x06, 0x07, 0x08, 0x19, 0x1a, 0x1b, 0x20, 0x23, 0x2b,
                        0x2f, 0x34, 0x35, 0x36, 0x37, 0x3a]

# sgx_sram_ptr: macOS maps 0x8000 bytes of phys 0x288d60000 (= FenderRegsMCW's
# base) at a separate kernel VA with Shared attributes (PTE 0x..44b).
SGX_SRAM_PHYS_T6040 = 0x288D60000
SGX_SRAM_SIZE_T6040 = 0x8000

# SNAPSHOT: HwDataB head (+0..+0x640), nonzero u64s. Layout matches 13.x
# (>= 13.0b4): unk_8, unk_18, unk_20, unk_28, unk_30, timestamp_region_base
# (+0x28), pad, yuv_matrices[63][3][4] i16 at +0x50, pad -> exactly 0x640.
# macOS fills only a few matrices.
HWDATAB_HEAD_QWORDS = {
    0x00: 0x6F00000000, 0x08: 0xFFC00000, 0x10: 0x1000000000, 0x18: 0x1000000000,
    0x20: 0x2FFFFFF8000,
    # 0x28: timestamp_region_base (pointer, filled by the builder)
    0xE0: 0x2008, 0xE8: 0x20080000, 0xF0: 0x200800000000, 0xF8: 0xC98A2CFA000024CB,
    0x100: 0x1877E917F4F624CB, 0x108: 0xBDAB000038D924CB,
    0x2D8: 0xD32D2CDBFFF82000, 0x2E0: 0x21DAE926F5002000, 0x2E8: 0xC742000838B62000,
    0x3E0: 0x7FE0, 0x3E8: 0x7FE00000, 0x3F0: 0x7FE000000000,
    0x3F8: 0x8000, 0x400: 0x80000000, 0x408: 0x800000000000,
    0x5D8: 0xE984B232645, 0x5E0: 0x40003FFFD5A2EA5F, 0x5E8: 0x4000F5A2CA5E4000,
}

# SNAPSHOT: scalar constants of HwDataB (names from lib/agx/hwdata.ml).
HWDATAB_CONSTANTS_T6040 = dict(
    sram_size=SGX_SRAM_SIZE_T6040,
    unk_fb4=[1, 1, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0],
    base_clock_khz=24000,
    unk_ff0=1,
    unk_49c=[1, 1, 1],
    unk_4c0=0x1f,
    unk_4e0=0xC07002004,
    unk_4e8=[0, 0, 1, 1, 0, 0, 0],
    unk_504=0x31,
    unk_524=1,
    num_frags=20,
    gpu_core=19,           # G16
    gpu_rev=4,
    num_cores=20,          # 2 clusters x 10 slots (16 enabled; core mask is SGX +0xe01500)
    cs_table=bytes(0x148),
    unk_2660=5,
    unk_ae4=[6, 3, 7, 7],
    unk_2688=[0, 0x10, 0, 1],
    unk_26b0=0x1E0000,
    unk_b24=[1, 1],
    unk_b2c=1,
    unk_b34=1,
    unk_b38_0=[1, 1],
    unk_b38=[0xFFFFFFFFFFFFFFFF] * 6,
    gin1114_swwa=2,
    kick_defer_enable=1,
    sched_pause_timeout_us=150,
    trace_enable=1,
    unk_2734=1,
    unk_273c=0x100,
    unk_27e8=1,
    unk_27ec=1,
    unk_281c=1,
    hrb_mode=0,
    unk_2846=1,
    unk_284a=1,
)

# --------------------------------------------------------------------------
# GPU VA plan

@dataclass
class Mapping:
    va: int
    phys: int
    size: int
    kind: str      # "device" (AttrIndex 1), "shared" (2), "normal" (0); macOS PTE low bits 0x447/0x44b/0x443
    name: str = ""


def alloc_io_vas(slots, base=IO_VA_BASE_MACOS):
    """VA per io slot with macOS's rule (reproduces all 25 macOS VAs): slot order,
    page offset kept, round_up(off + size, 16K) + one 16K guard page, start
    aligned to 32K."""
    va, out = base, {}
    for slot, phys, size, *_ in slots:
        off = phys & (PAGE - 1)
        va = (va + 0x7FFF) & ~0x7FFF
        out[slot] = va + off
        va += ((off + size + PAGE - 1) & ~(PAGE - 1)) + PAGE
    return out


def build_io_mappings(slots=IO_MAPPINGS_T6040, empty_flag2=IO_EMPTY_FLAG2_T6040, base=IO_VA_BASE_MACOS):
    """(list of 60 IOMapping27 dicts, list of Mapping for the UAT)."""
    vas = alloc_io_vas(slots, base)
    entries = [L.IOMapping27.default() for _ in range(60)]
    maps = []
    for slot, phys, size, rsize, rw, flags in slots:
        entries[slot] = dict(phys_addr=phys, virt_addr=vas[slot], size=size, range_size=rsize,
                             sgx_offset=(phys - SGX_REG_BASE) if rw else 0, flags=flags)
        off = phys & (PAGE - 1)
        maps.append(Mapping(vas[slot] - off, phys - off, (off + size + PAGE - 1) & ~(PAGE - 1),
                            "device", L.REGION_NAMES.get(slot, f"slot{slot:#x}")))
    for slot in empty_flag2:
        entries[slot]["flags"] = 2
    return entries, maps

# --------------------------------------------------------------------------
# HwDataB

@dataclass
class HwDataBPointers:
    """Every GPU VA HwDataB holds. Defaults are placeholders, not macOS's."""
    timestamp_region_base: int = 0xFFFFFC2181400000   # SNAPSHOT VA; TODO what backs it
    sgx_sram_ptr: int = 0xFFFFFC2000108000
    counter_ctl: int = 0                              # GPU VA of a host page of counter thresholds
    unk_27e0: int = 0                                 # GPU VA, unknown
    hw_rings: list = field(default_factory=lambda: [None] * 4)  # per array index: (gpu_va, fw_va, hw_slot) or None
                                                      # (macOS: index 0 slot 0, index 2 slot 2)
    io_va_base: int = IO_VA_BASE_MACOS


def _f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def dvfs_fields(g: GpuAdt, maps=PSTATE_MAP_T6040, rel_max_powers=REL_MAX_POWERS_T6040):
    """HwDataB DVFS block from the ADT (rules: lib/agx/hwdata.ml)."""
    main, alt = maps
    n = len(main)                     # 11 live pstates
    assert n == len(alt) and n <= 16
    f = {}
    zero16 = [0] * 16

    def rows(mapping, tables, ncols):
        out = []
        for i in range(16):
            if i < n:
                k = mapping[i]
                c0, c1 = tables[0][k][1], tables[1][k][1]
                out.append([c0, c1] + [c0] * (14 if ncols == 16 else 0) + [0] * (14 if ncols == 2 else 0))
            else:
                out.append(list(zero16))
        return out

    freqs = [g.perf[0][k][0] for k in main] + [0] * (16 - n)
    freqs_alt = [g.perf[0][k][0] for k in alt] + [0] * (16 - n)
    f["max_pstate"] = n - 1
    f["frequencies"] = freqs
    # 16 columns: 0/1 = ADT tables 0/1 (per die), 2..15 copies of column 0.
    f["voltages"] = rows(main, g.perf, 16)
    f["voltages_sram"] = rows(main, g.perf_sram, 16)
    f["frequencies_alt"] = freqs_alt
    f["unk_9b4"] = [1.02] * n + [0.0] * (16 - n)
    f["rel_max_powers"] = list(rel_max_powers) + [0.0] * (16 - len(rel_max_powers))
    f1, fmax = freqs[1], freqs[n - 1]
    # (f - f[1]) / (f[max] - f[1]) * 100. macOS's exact float order is unknown: plain
    # double is 1 ulp off at 3 entries; normalising by f[max] in f32 first matches
    # 10 of 11 (entry 8 stays 1 ulp off). Harmless, but noted.
    r1 = _f32(f1 / fmax)
    f["rel_boost_freqs"] = [max(0.0, _f32((_f32(freqs[i] / fmax) - r1) / (1.0 - r1) * 100.0)) if i < n else 0.0
                            for i in range(16)]
    f["pstate_map"] = [main + [0] * (16 - n), alt + [0] * (16 - n)]
    # AFR (13.x: 8 entries; 27.2: 16)
    na = len(g.afr)
    f["afr_pstate_limit"] = na - 1
    f["afr_max_pstate"] = na - 1
    f["afr_frequencies"] = [a[0] for a in g.afr] + [0] * (16 - na)
    f["afr_voltages"] = [[a[1], 0] for a in g.afr] + [[0, 0]] * (16 - na)
    f["afr_voltages_sram"] = [[max(a[1], g.afr_min_sram_mv), 0] for a in g.afr] + [[0, 0]] * (16 - na)
    # Alternate curve, full table; only columns 0/1 are filled (unlike the main table).
    f["max_pstate_alt"] = n - 1
    f["frequencies_alt2"] = freqs_alt
    f["voltages_alt"] = rows(alt, g.perf, 2)
    f["voltages_sram_alt"] = rows(alt, g.perf_sram, 2)
    return f


def hwdata_b_values(g: GpuAdt, ptrs: HwDataBPointers, maps=PSTATE_MAP_T6040):
    io, uat_maps = build_io_mappings(base=ptrs.io_va_base)
    v = dict(HWDATAB_CONSTANTS_T6040)
    v.update(
        io_mappings=io,
        sgx_sram_ptr=ptrs.sgx_sram_ptr,
        chip_id=g.chip_id,
        power_sample_period=g.power_sample_period,
        unk_10a8=g.num_perf_states,
        counter_ctl=ptrs.counter_ctl,
        unk_27e0=ptrs.unk_27e0,
    )
    v.update(dvfs_fields(g, maps))
    rings = [L.HwRing27.default() for _ in range(4)]
    for i, r in enumerate(ptrs.hw_rings):
        if r is None:
            continue
        gva, fva, slot = r
        rings[i] = dict(gpu_va=gva, fw_va=fva, size=0x800, entry_size=0x40, hw_slot=slot, fw_state=0)
    v["hw_rings"] = rings
    head = bytearray(0x640)
    for off, q in HWDATAB_HEAD_QWORDS.items():
        struct.pack_into("<Q", head, off, q)
    struct.pack_into("<Q", head, 0x28, ptrs.timestamp_region_base)
    v["head"] = bytes(head)
    uat_maps.append(Mapping(ptrs.sgx_sram_ptr, SGX_SRAM_PHYS_T6040, SGX_SRAM_SIZE_T6040, "shared", "sgx_sram"))
    return v, uat_maps


def build_hwdata_b(g: GpuAdt, ptrs: HwDataBPointers = None, maps=PSTATE_MAP_T6040):
    """(bytes[0x2850], [Mapping]) for HwDataB27."""
    v, m = hwdata_b_values(g, ptrs or HwDataBPointers(), maps)
    return L.HwDataB27.build(v), m

# --------------------------------------------------------------------------
# InitData, RegionB

def uat_level_info():
    """As InitData declares it (identical to the snapshot): 36/25/14, 64/2048/2048."""
    out = []
    for shift, n, imask in ((36, 64, 0x3F000000000), (25, 2048, 0xFFE000000), (14, 2048, 0x1FFC000)):
        out.append(dict(unk_3=8, unk_1=14, unk_2=14, index_shift=shift, num_entries=n,
                        unk_4=0x4000, unk_8=1, phys_mask=0x3FFFFFFC000, index_mask=imask))
    return out


def build_initdata(region_a, region_b, region_c, ptr_a8, ptr_b0, ptr_b8, ptr_c0):
    """InitData27 bytes. All arguments are kernel-half GPU VAs."""
    return L.InitData27.build(dict(
        ver_info=L.INITDATA_FINGERPRINT_27_2,
        region_a=region_a, region_b=region_b, region_c=region_c,
        unk_28=0, host_mapped_fw_allocations_27=1,
        uat_page_size=0x4000, uat_page_bits=14, uat_num_levels=3,
        uat_level_info=uat_level_info(),
        ptr_a8=ptr_a8, ptr_b0=ptr_b0, ptr_b8=ptr_b8, ptr_c0=ptr_c0,
    ))


def queue_state_va(state_base, kind, index):
    """Per-queue counter block: TA +0x000, 3D +0x100, CL +0x200, 0x40 each, queues reversed."""
    return state_base + {"ta": 0, "3d": 0x100, "cl": 0x200}[kind] + 0x40 * (3 - index)


def build_regionb(hwdata_b, hdr_ptr, state_base, ring_base, devctrl_state, devctrl_ring, aux=None):
    """RegionB27 head: 13 channel records. Rings 0x1800 apart in channel order
    (macOS's order differs; any order should do). TODO: aux channels at +0x1c0
    and everything after are not decoded: [aux] is passed through raw."""
    q = {}
    for name in L.QUEUE_CHANNELS[:-1]:
        kind, idx = name.split("_"); idx = int(idx)
        st = queue_state_va(state_base, kind, idx)
        q[name] = dict(read_ptr=st, ptr_10=st + 0x10, write_ptr=st + 0x20,
                       ring=ring_base + 0x1800 * L.QUEUE_CHANNELS.index(name))
    q["dev_ctrl"] = dict(read_ptr=devctrl_state, ptr_10=devctrl_state + 0x10,
                         write_ptr=devctrl_state + 0x20, ring=devctrl_ring)
    v = dict(hwdata_b=hwdata_b, hdr_ptr_08=hdr_ptr, hdr_ptr_10=hdr_ptr, hdr_18=0, queues=q)
    if aux is not None:
        v["aux"] = aux
    return L.RegionB27.build(v)


def msg_initdata(initdata_va):
    """EP 0x20 message: type 0x81 in bits 63:48, pointer in 47:0. The firmware
    ORs 0xfffff00000000000 back in, so the VA must be in the kernel half."""
    assert initdata_va >> 44 == 0xFFFFF, f"{initdata_va:#x} not a kernel-half VA"
    return (0x81 << 48) | (initdata_va & 0xFFFFFFFFFFFF)

# --------------------------------------------------------------------------
# Self-test against the macOS snapshot

def _float_eq(a, b):
    return struct.pack("<f", a) == struct.pack("<f", b)


def selftest(adt_path, snap_dir, hwdb_va=0xFFFFFC20C07A0000):
    import snapshot as S
    g = GpuAdt.from_adt(load_adt(adt_path))
    print(f"ADT: chip {g.chip_id:#x}, {g.num_perf_states} perf states, "
          f"{len(g.perf)} tables x {len(g.perf[0])}, AFR {len(g.afr)} states")

    snap = S.Snapshot(snap_dir)
    ref = snap.read(hwdb_va, L.HwDataB27.size)
    assert ref is not None, "HwDataB not in snapshot"
    r = L.HwDataB27.parse(ref)
    assert ref[:8] != bytes(8)

    # Cross-checks of the rules against macOS
    assert r["pstate_map"][0][:11] == PSTATE_MAP_T6040[0] and r["pstate_map"][1][:11] == PSTATE_MAP_T6040[1]
    assert snap.translate(r["sgx_sram_ptr"]) == SGX_SRAM_PHYS_T6040

    def run(label, ptrs):
        mine, maps = build_hwdata_b(g, ptrs)
        diff = [i for i in range(len(mine)) if mine[i] != ref[i]]
        fields = {}
        for i in diff:
            fields.setdefault(L.HwDataB27.field_at(i).split("+")[0], []).append(i)
        print(f"\n[{label}] {len(diff)} of {len(mine):#x} bytes differ, in {len(fields)} fields")
        for k, v in sorted(fields.items(), key=lambda kv: kv[1][0]):
            print(f"  +{v[0]:#06x} {k:32s} {len(v):3d} bytes")
        return mine, maps, fields

    # 1) Our own pointers (what a host boot would use): only pointer fields may differ.
    own = HwDataBPointers(timestamp_region_base=0xFFFFFC2201400000, sgx_sram_ptr=0xFFFFFC2200108000,
                          counter_ctl=0xFFFFFC2201548000, unk_27e0=0xFFFFFC2201540000,
                          hw_rings=[(0x7201848000, 0xFFFFFC22000E8000, 0), None, (0x7201870000, 0xFFFFFC2200E10000, 2), None],
                          io_va_base=0xFFFFFC2280000000)
    run("own VAs", own)

    # 2) macOS's pointers plugged in: what is left is what the ADT rules + constants get wrong.
    mac = HwDataBPointers(
        timestamp_region_base=struct.unpack_from("<Q", ref, 0x28)[0],
        sgx_sram_ptr=r["sgx_sram_ptr"], counter_ctl=r["counter_ctl"], unk_27e0=r["unk_27e0"],
        hw_rings=[(x["gpu_va"], x["fw_va"], x["hw_slot"]) if x["size"] else None for x in r["hw_rings"]],
        io_va_base=IO_VA_BASE_MACOS)
    mine, maps, fields = run("macOS VAs", mac)
    expected = {"hw_rings.0.fw_state"}   # written by the firmware (0x601), host writes 0
    def ulp1(k):
        if not k.startswith("rel_boost_freqs."):
            return False
        o = L.HwDataB27.offset(k)
        a, b = struct.unpack_from("<i", mine, o)[0], struct.unpack_from("<i", ref, o)[0]
        return abs(a - b) <= 1
    rounding = {k for k in fields if ulp1(k)}
    if rounding:
        print(f"within 1 ulp (float evaluation order): {sorted(rounding)}")
    unexpected = set(fields) - expected - rounding
    print(f"\nunexpected differences with macOS VAs: {sorted(unexpected) or 'none'}")
    print(f"UAT mappings HwDataB needs: {len(maps)} ({sum(m.size for m in maps):#x} bytes)")

    # InitData: rebuild with macOS pointers and compare the 0xc8 bytes.
    iva = snap.init_va()
    iref = snap.read(iva, L.InitData27.size)
    ir = L.InitData27.parse(iref)
    imine = build_initdata(ir["region_a"], ir["region_b"], ir["region_c"],
                           ir["ptr_a8"], ir["ptr_b0"], ir["ptr_b8"], ir["ptr_c0"])
    idiff = sum(a != b for a, b in zip(imine, iref))
    print(f"InitData @ {iva:#x}: {idiff} of {len(imine):#x} bytes differ (macOS pointers plugged in)")
    print(f"init message: {msg_initdata(iva):#018x}")
    return not unexpected and idiff == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--adt", default=os.path.join(REPO, "build", "adt.bin"))
    ap.add_argument("--snap", default=os.path.join(REPO, "build", "agx", "traces", "27.2-boot5", "03-after-5000-msgs"))
    a = ap.parse_args()
    ok = selftest(a.adt, a.snap)
    print("\nSELFTEST", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
